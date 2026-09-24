-- Security hardening v2
-- Run once in Supabase SQL Editor. This is the single migration for RPC,
-- earn proof, redemption pricing, bonuses, registration tombstones,
-- QR storage, Battleship idempotency and abuse/audit infrastructure.

BEGIN;

-- --------------------------------------------------------------------------
-- Persistent identity ownership. No FK on user_id by design: deleting an
-- account must not erase the IP/device/browser tombstone.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS abuse_identities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind TEXT NOT NULL CHECK (kind IN ('ip', 'device', 'browser')),
  value_hash TEXT NOT NULL,
  user_id UUID NOT NULL,
  blocked BOOLEAN NOT NULL DEFAULT FALSE,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (kind, value_hash)
);

CREATE INDEX IF NOT EXISTS idx_abuse_identities_user ON abuse_identities(user_id);
ALTER TABLE abuse_identities ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS abuse_events (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID,
  action TEXT NOT NULL,
  reason TEXT NOT NULL,
  ip_hash TEXT,
  device_hash TEXT,
  browser_hash TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_abuse_events_user_created
  ON abuse_events(user_id, created_at DESC);
ALTER TABLE abuse_events ENABLE ROW LEVEL SECURITY;

-- Preserve old registration ownership after auth user deletion.
ALTER TABLE registration_limits DROP CONSTRAINT IF EXISTS registration_limits_user_id_fkey;
DROP POLICY IF EXISTS "Self update profile" ON profiles;
DROP POLICY IF EXISTS "Self profile update" ON profiles;
ALTER TABLE registration_limits ADD COLUMN IF NOT EXISTS browser_hash TEXT;
ALTER TABLE registration_limits ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
CREATE UNIQUE INDEX IF NOT EXISTS registration_limits_browser_hash_key
  ON registration_limits(browser_hash) WHERE browser_hash IS NOT NULL;

INSERT INTO abuse_identities(kind,value_hash,user_id,first_seen_at,last_seen_at)
SELECT 'ip',ip_hash,user_id,created_at,updated_at FROM registration_limits
ON CONFLICT(kind,value_hash) DO NOTHING;
INSERT INTO abuse_identities(kind,value_hash,user_id,first_seen_at,last_seen_at)
SELECT 'device',device_hash,user_id,created_at,updated_at FROM registration_limits
ON CONFLICT(kind,value_hash) DO NOTHING;
INSERT INTO abuse_identities(kind,value_hash,user_id,first_seen_at,last_seen_at)
SELECT 'browser',browser_hash,user_id,created_at,updated_at FROM registration_limits WHERE browser_hash IS NOT NULL
ON CONFLICT(kind,value_hash) DO NOTHING;

CREATE OR REPLACE FUNCTION claim_abuse_identity(
  p_user_id UUID,
  p_ip_hash TEXT,
  p_device_hash TEXT,
  p_browser_hash TEXT,
  p_action TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_conflict abuse_identities%ROWTYPE;
  v_profile profiles%ROWTYPE;
BEGIN
  SELECT * INTO v_profile FROM profiles WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND OR v_profile.is_banned THEN
    RAISE EXCEPTION 'ACCOUNT_RESTRICTED';
  END IF;

  IF COALESCE(length(p_ip_hash), 0) < 32
     OR COALESCE(length(p_device_hash), 0) < 32
     OR COALESCE(length(p_browser_hash), 0) < 32 THEN
    RAISE EXCEPTION 'IDENTITY_PROOF_REQUIRED';
  END IF;

  SELECT * INTO v_conflict
  FROM abuse_identities
  WHERE (kind = 'device' AND value_hash = p_device_hash)
     OR (kind = 'browser' AND value_hash = p_browser_hash)
  ORDER BY first_seen_at
  LIMIT 1
  FOR UPDATE;

  IF FOUND AND (v_conflict.user_id <> p_user_id OR v_conflict.blocked) THEN
    INSERT INTO abuse_events(user_id, action, reason, ip_hash, device_hash, browser_hash, metadata)
    VALUES (p_user_id, p_action, 'identity_owned_by_another_account', p_ip_hash,
            p_device_hash, p_browser_hash,
            jsonb_build_object('owner_user_id', v_conflict.user_id, 'kind', v_conflict.kind));
    RAISE EXCEPTION 'IDENTITY_CONFLICT';
  END IF;

  INSERT INTO abuse_identities(kind, value_hash, user_id)
  VALUES
    ('ip', p_ip_hash, p_user_id),
    ('device', p_device_hash, p_user_id),
    ('browser', p_browser_hash, p_user_id)
  ON CONFLICT (kind, value_hash) DO UPDATE SET last_seen_at = NOW();

  RETURN jsonb_build_object('allowed', true);
END;
$$;

-- --------------------------------------------------------------------------
-- Earn proof is one-time and server-owned. Direct table reads are removed so
-- authenticated users cannot obtain task tokens through PostgREST.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS earn_entry_proofs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id UUID NOT NULL REFERENCES earn_tasks(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  proof_hash TEXT NOT NULL UNIQUE,
  ip_hash TEXT NOT NULL,
  device_hash TEXT NOT NULL,
  browser_hash TEXT NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  UNIQUE (task_id)
);
ALTER TABLE earn_entry_proofs ENABLE ROW LEVEL SECURITY;

-- Clean legacy duplicates before enforcing one pending task per user.
-- Expired pending tasks are rejected; among remaining duplicates only the
-- newest task is kept pending.
UPDATE earn_tasks
SET status = 'rejected'
WHERE status = 'pending'
  AND expires_at <= NOW();

WITH ranked_pending AS (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY user_id
           ORDER BY created_at DESC, id DESC
         ) AS row_number
  FROM earn_tasks
  WHERE status = 'pending'
)
UPDATE earn_tasks task
SET status = 'rejected'
FROM ranked_pending ranked
WHERE task.id = ranked.id
  AND ranked.row_number > 1;

CREATE UNIQUE INDEX IF NOT EXISTS earn_tasks_one_active_per_user
  ON earn_tasks(user_id) WHERE status='pending';

DROP POLICY IF EXISTS "User có thể xem task của chính mình" ON earn_tasks;
DROP POLICY IF EXISTS "User co the xem task cua chinh minh" ON earn_tasks;
REVOKE ALL ON TABLE earn_tasks FROM anon, authenticated;
REVOKE ALL ON TABLE earn_entry_proofs FROM anon, authenticated;

CREATE OR REPLACE FUNCTION complete_earn_task_secure(
  p_task_id UUID,
  p_user_id UUID,
  p_proof_hash TEXT,
  p_ip_hash TEXT,
  p_device_hash TEXT,
  p_browser_hash TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_task earn_tasks%ROWTYPE;
  v_proof earn_entry_proofs%ROWTYPE;
BEGIN
  SELECT * INTO v_task FROM earn_tasks WHERE id = p_task_id FOR UPDATE;
  IF NOT FOUND OR v_task.user_id <> p_user_id THEN RAISE EXCEPTION 'TASK_NOT_FOUND'; END IF;
  IF v_task.status <> 'pending' THEN RAISE EXCEPTION 'TASK_ALREADY_PROCESSED'; END IF;
  IF v_task.expires_at <= NOW() THEN RAISE EXCEPTION 'TASK_EXPIRED'; END IF;

  SELECT * INTO v_proof
  FROM earn_entry_proofs
  WHERE task_id = p_task_id AND user_id = p_user_id AND proof_hash = p_proof_hash
  FOR UPDATE;
  IF NOT FOUND OR v_proof.consumed_at IS NOT NULL OR v_proof.expires_at <= NOW() THEN
    RAISE EXCEPTION 'INVALID_ENTRY_PROOF';
  END IF;
  IF v_proof.ip_hash <> p_ip_hash OR v_proof.device_hash <> p_device_hash
     OR v_proof.browser_hash <> p_browser_hash THEN
    RAISE EXCEPTION 'ENTRY_IDENTITY_MISMATCH';
  END IF;
  IF v_proof.issued_at < v_task.created_at + INTERVAL '8 seconds' THEN
    RAISE EXCEPTION 'ENTRY_TOO_FAST';
  END IF;

  UPDATE earn_entry_proofs SET consumed_at = NOW() WHERE id = v_proof.id;
  UPDATE earn_tasks SET status = 'completed', completed_at = NOW() WHERE id = p_task_id;
  PERFORM process_cam_transaction(p_user_id, 'earn', v_task.reward_cam,
    'Vuot link (' || v_task.provider_code || ')', v_task.id);
  RETURN jsonb_build_object('task_id', v_task.id, 'reward_cam', v_task.reward_cam);
END;
$$;

-- --------------------------------------------------------------------------
-- Server-authoritative redemption pricing.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_redemption_request_secure(
  p_user_id UUID,
  p_type redeem_type,
  p_requested_cam NUMERIC(12,4),
  p_provider TEXT,
  p_denomination NUMERIC(15,0),
  p_details JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_amount_cam NUMERIC(12,4);
  v_amount_vnd NUMERIC(15,0);
  v_rate INTEGER;
  v_ticket_id UUID;
  v_latest TIMESTAMPTZ;
  v_used_free INTEGER := 0;
  v_required INTEGER := 0;
  v_qualified INTEGER := 0;
  v_allowed_denoms NUMERIC[] := ARRAY[5000,10000,20000,30000,50000,100000,200000,300000,500000,1000000];
BEGIN
  SELECT created_at INTO v_latest FROM redemptions
  WHERE user_id = p_user_id AND status <> 'rejected'
  ORDER BY created_at DESC LIMIT 1;
  IF v_latest IS NOT NULL AND v_latest > NOW() - INTERVAL '12 hours' THEN
    RAISE EXCEPTION 'REDEEM_COOLDOWN';
  END IF;

  IF p_type = 'bank' THEN
    IF p_requested_cam < 44 OR p_requested_cam <> trunc(p_requested_cam, 4) THEN
      RAISE EXCEPTION 'INVALID_BANK_AMOUNT';
    END IF;
    IF COALESCE(p_details->>'info', '') = '' AND COALESCE(p_details->>'qrCodeUrl', '') = '' THEN
      RAISE EXCEPTION 'BANK_DETAILS_REQUIRED';
    END IF;
    v_rate := CASE WHEN COALESCE(p_details->>'qrCodeUrl', '') <> '' THEN 220 ELSE 200 END;
    v_amount_cam := p_requested_cam;
    v_amount_vnd := floor(v_amount_cam * v_rate);
  ELSIF p_type IN ('phone_card', 'game_card') THEN
    IF p_provider IS NULL OR p_denomination IS NULL OR NOT (p_denomination = ANY(v_allowed_denoms)) THEN
      RAISE EXCEPTION 'INVALID_CARD_PRODUCT';
    END IF;
    IF p_type = 'phone_card' AND lower(p_provider) NOT IN ('viettel','vinaphone','mobifone','vietnamobile') THEN
      RAISE EXCEPTION 'INVALID_CARD_PROVIDER';
    END IF;
    IF p_type = 'game_card' AND lower(p_provider) NOT IN ('garena','zing','vcoin') THEN
      RAISE EXCEPTION 'INVALID_CARD_PROVIDER';
    END IF;
    v_amount_vnd := p_denomination;
    v_amount_cam := ceil(v_amount_vnd / 250.0);
    p_details := jsonb_build_object('provider', p_provider, 'denomination', p_denomination);
  ELSE
    RAISE EXCEPTION 'INVALID_REDEEM_TYPE';
  END IF;

  IF p_type IN ('phone_card', 'game_card') THEN
    SELECT COUNT(*) INTO v_used_free FROM redemptions
    WHERE user_id = p_user_id AND type IN ('phone_card','game_card') AND status <> 'rejected';
  END IF;
  IF p_type = 'bank' OR v_used_free >= 3 THEN
    v_required := CASE WHEN v_amount_vnd <= 50000 THEN 1 WHEN v_amount_vnd <= 100000 THEN 3
                       WHEN v_amount_vnd <= 500000 THEN 5 ELSE 10 END;
    SELECT COUNT(*) INTO v_qualified FROM profiles r
    WHERE r.referred_by = p_user_id AND EXISTS (
      SELECT 1 FROM earn_tasks t WHERE t.user_id = r.id AND t.status = 'completed');
    IF v_qualified < v_required THEN RAISE EXCEPTION 'QUALIFIED_REFERRALS_REQUIRED'; END IF;
  END IF;

  PERFORM process_cam_transaction(p_user_id, 'redeem', v_amount_cam, 'Tao yeu cau rut thuong', NULL);
  INSERT INTO redemptions(user_id,type,amount_cam,amount_vnd,status,details)
  VALUES(p_user_id,p_type,v_amount_cam,v_amount_vnd,'pending',COALESCE(p_details,'{}'::jsonb))
  RETURNING id INTO v_ticket_id;
  RETURN jsonb_build_object('ticket_id',v_ticket_id,'amount_cam',v_amount_cam,'amount_vnd',v_amount_vnd);
END;
$$;

-- --------------------------------------------------------------------------
-- Bonus period and eligibility are computed in the same DB transaction.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bonus_claims (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  bonus_type TEXT NOT NULL,
  period TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, bonus_type, period)
);
ALTER TABLE bonus_claims ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own bonus claims" ON bonus_claims FOR SELECT USING (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION process_bonus_claim_secure(p_user_id UUID, p_bonus_type TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_requirement NUMERIC;
  v_reward NUMERIC(12,4);
  v_period TEXT;
  v_count NUMERIC;
  v_claim UUID;
  v_start TIMESTAMPTZ;
  v_desc TEXT;
BEGIN
  IF p_bonus_type LIKE 'daily_%' THEN
    v_requirement := CASE p_bonus_type WHEN 'daily_30' THEN 30 WHEN 'daily_60' THEN 60 WHEN 'daily_100' THEN 100 ELSE NULL END;
    v_reward := CASE p_bonus_type WHEN 'daily_30' THEN 8 WHEN 'daily_60' THEN 10 WHEN 'daily_100' THEN 12 END;
    v_period := to_char(timezone('Asia/Ho_Chi_Minh', NOW()), 'YYYY-MM-DD');
    v_start := date_trunc('day', timezone('Asia/Ho_Chi_Minh', NOW())) AT TIME ZONE 'Asia/Ho_Chi_Minh';
    SELECT COUNT(*) INTO v_count FROM earn_tasks
    WHERE user_id=p_user_id AND status='completed' AND completed_at >= v_start;
    v_desc := 'Thuong them: Dat moc ' || v_requirement || ' nhiem vu ngay';
  ELSIF p_bonus_type LIKE 'weekly_%' THEN
    v_requirement := CASE p_bonus_type WHEN 'weekly_10' THEN 10 WHEN 'weekly_28' THEN 28 WHEN 'weekly_60' THEN 60 ELSE NULL END;
    v_reward := CASE p_bonus_type WHEN 'weekly_10' THEN 16 WHEN 'weekly_28' THEN 20 WHEN 'weekly_60' THEN 32 END;
    v_period := to_char(timezone('Asia/Ho_Chi_Minh', NOW()), 'IYYY-"W"IW');
    v_start := date_trunc('week', timezone('Asia/Ho_Chi_Minh', NOW())) AT TIME ZONE 'Asia/Ho_Chi_Minh';
    SELECT COALESCE(SUM(amount),0) INTO v_count FROM cam_transactions
    WHERE user_id=p_user_id AND type='referral_bonus' AND created_at >= v_start;
    v_desc := 'Thuong them: Hoa hong tuan dat ' || v_requirement || ' Cam';
  ELSE
    RAISE EXCEPTION 'INVALID_BONUS_TYPE';
  END IF;
  IF v_requirement IS NULL OR v_count < v_requirement THEN RAISE EXCEPTION 'BONUS_NOT_ELIGIBLE'; END IF;
  INSERT INTO bonus_claims(user_id,bonus_type,period) VALUES(p_user_id,p_bonus_type,v_period)
  RETURNING id INTO v_claim;
  PERFORM process_cam_transaction(p_user_id,'earn',v_reward,v_desc,v_claim);
  RETURN jsonb_build_object('claim_id',v_claim,'reward',v_reward,'period',v_period);
END;
$$;

-- --------------------------------------------------------------------------
-- Battleship event idempotency and settlement integrity.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS battleship_matches (
  match_id TEXT PRIMARY KEY,
  player_ids UUID[] NOT NULL,
  amount NUMERIC(12,4) NOT NULL CHECK(amount > 0),
  tier TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('started','finished','cancelled')),
  winner_id UUID,
  loser_id UUID,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  settled_at TIMESTAMPTZ,
  replay_hash TEXT
);
ALTER TABLE battleship_matches ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION process_battleship_event(
  p_match_id TEXT, p_status TEXT, p_player_ids UUID[], p_amount NUMERIC,
  p_tier TEXT, p_winner_id UUID, p_loser_id UUID, p_reason TEXT, p_replay_hash TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_match battleship_matches%ROWTYPE; v_player UUID; v_payout NUMERIC(12,4);
BEGIN
  IF p_match_id IS NULL OR array_length(p_player_ids,1) <> 2 OR p_player_ids[1]=p_player_ids[2]
     OR p_amount NOT IN (4,12,20,40,80,200) THEN RAISE EXCEPTION 'INVALID_MATCH'; END IF;

  IF p_status='match_start' THEN
    INSERT INTO battleship_matches(match_id,player_ids,amount,tier,status)
    VALUES(p_match_id,p_player_ids,p_amount,p_tier,'started') ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN RETURN jsonb_build_object('idempotent',true); END IF;
    FOREACH v_player IN ARRAY p_player_ids LOOP
      PERFORM process_cam_transaction(v_player,'fee',p_amount,'Battleship cuoc '||p_amount||' CAM - '||p_match_id,NULL);
    END LOOP;
    RETURN jsonb_build_object('started',true);
  END IF;

  SELECT * INTO v_match FROM battleship_matches WHERE match_id=p_match_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MATCH_NOT_STARTED'; END IF;
  IF v_match.status <> 'started' THEN RETURN jsonb_build_object('idempotent',true); END IF;
  IF v_match.amount<>p_amount OR v_match.player_ids<>p_player_ids THEN RAISE EXCEPTION 'MATCH_CONTEXT_MISMATCH'; END IF;

  IF p_status='finished' THEN
    IF p_winner_id IS NULL OR NOT (p_winner_id=ANY(v_match.player_ids))
       OR p_loser_id IS NULL OR p_winner_id=p_loser_id THEN RAISE EXCEPTION 'INVALID_WINNER'; END IF;
    v_payout := p_amount*2-round(p_amount*0.05,4);
    PERFORM process_cam_transaction(p_winner_id,'admin_adjust_add',v_payout,
      'Battleship thang +'||v_payout||' CAM (fee 5%) - '||p_match_id,NULL);
    UPDATE battleship_matches SET status='finished',winner_id=p_winner_id,loser_id=p_loser_id,
      settled_at=NOW(),replay_hash=p_replay_hash WHERE match_id=p_match_id;
  ELSIF p_status='cancelled' THEN
    FOREACH v_player IN ARRAY v_match.player_ids LOOP
      PERFORM process_cam_transaction(v_player,'admin_adjust_add',p_amount,
        'Battleship huy - hoan cuoc '||p_amount||' CAM - '||p_match_id,NULL);
    END LOOP;
    UPDATE battleship_matches SET status='cancelled',settled_at=NOW() WHERE match_id=p_match_id;
  ELSE RAISE EXCEPTION 'INVALID_MATCH_STATUS'; END IF;
  RETURN jsonb_build_object('settled',true);
END;
$$;

-- --------------------------------------------------------------------------
-- QR files are private and owned by the first path segment (auth.uid()).
-- --------------------------------------------------------------------------
UPDATE storage.buckets SET public = FALSE WHERE id = 'qrcodes';
DROP POLICY IF EXISTS "Public Access" ON storage.objects;
DROP POLICY IF EXISTS "Auth Upload" ON storage.objects;
DROP POLICY IF EXISTS "Auth Delete" ON storage.objects;
DROP POLICY IF EXISTS "QR owner upload" ON storage.objects;
DROP POLICY IF EXISTS "QR owner read" ON storage.objects;
DROP POLICY IF EXISTS "QR owner delete" ON storage.objects;
CREATE POLICY "QR owner upload" ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id='qrcodes' AND (storage.foldername(name))[1]=auth.uid()::TEXT);
CREATE POLICY "QR owner read" ON storage.objects FOR SELECT TO authenticated
USING (bucket_id='qrcodes' AND (storage.foldername(name))[1]=auth.uid()::TEXT);
CREATE POLICY "QR owner delete" ON storage.objects FOR DELETE TO authenticated
USING (bucket_id='qrcodes' AND (storage.foldername(name))[1]=auth.uid()::TEXT);

-- --------------------------------------------------------------------------
-- Admin audit helper.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION write_admin_audit(
  p_admin_id UUID, p_action TEXT, p_target_id UUID, p_target_data JSONB,
  p_ip TEXT DEFAULT NULL, p_user_agent TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM profiles WHERE id=p_admin_id AND role='admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;
  INSERT INTO admin_audit_log(admin_id,action,target_id,target_data,ip,user_agent)
  VALUES(p_admin_id,p_action,p_target_id,COALESCE(p_target_data,'{}'::jsonb),p_ip,p_user_agent);
END; $$;

-- --------------------------------------------------------------------------
-- Lock every privileged function. Application server uses service_role.
-- --------------------------------------------------------------------------
ALTER FUNCTION process_cam_transaction(UUID,TEXT,NUMERIC,TEXT,UUID) SET search_path=public,pg_temp;
ALTER FUNCTION process_cam_transfer(UUID,TEXT,NUMERIC,NUMERIC,TEXT) SET search_path=public,pg_temp;
ALTER FUNCTION process_redemption_request(UUID,redeem_type,NUMERIC,NUMERIC,JSONB) SET search_path=public,pg_temp;
ALTER FUNCTION process_redemption_decision(UUID,redeem_status,TEXT,BOOLEAN) SET search_path=public,pg_temp;
ALTER FUNCTION process_earn_task_completion(UUID,UUID) SET search_path=public,pg_temp;
ALTER FUNCTION process_bonus_claim(UUID,TEXT,TEXT,NUMERIC,TEXT) SET search_path=public,pg_temp;

REVOKE EXECUTE ON FUNCTION process_cam_transaction(UUID,TEXT,NUMERIC,TEXT,UUID) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION process_cam_transfer(UUID,TEXT,NUMERIC,NUMERIC,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION process_redemption_request(UUID,redeem_type,NUMERIC,NUMERIC,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION process_redemption_decision(UUID,redeem_status,TEXT,BOOLEAN) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION process_earn_task_completion(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION process_bonus_claim(UUID,TEXT,TEXT,NUMERIC,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION claim_abuse_identity(UUID,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION complete_earn_task_secure(UUID,UUID,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION process_redemption_request_secure(UUID,redeem_type,NUMERIC,TEXT,NUMERIC,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION process_bonus_claim_secure(UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION process_battleship_event(TEXT,TEXT,UUID[],NUMERIC,TEXT,UUID,UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION write_admin_audit(UUID,TEXT,UUID,JSONB,TEXT,TEXT) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION process_cam_transaction(UUID,TEXT,NUMERIC,TEXT,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION process_cam_transfer(UUID,TEXT,NUMERIC,NUMERIC,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION process_redemption_decision(UUID,redeem_status,TEXT,BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION claim_abuse_identity(UUID,TEXT,TEXT,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION complete_earn_task_secure(UUID,UUID,TEXT,TEXT,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION process_redemption_request_secure(UUID,redeem_type,NUMERIC,TEXT,NUMERIC,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION process_bonus_claim_secure(UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION process_battleship_event(TEXT,TEXT,UUID[],NUMERIC,TEXT,UUID,UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION write_admin_audit(UUID,TEXT,UUID,JSONB,TEXT,TEXT) TO service_role;

DO $$ BEGIN
  IF to_regprocedure('refresh_weekly_top_current(boolean)') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION refresh_weekly_top_current(BOOLEAN) SET search_path=public,pg_temp';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION refresh_weekly_top_current(BOOLEAN) FROM PUBLIC,anon,authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION refresh_weekly_top_current(BOOLEAN) TO service_role';
  END IF;
  IF to_regprocedure('award_previous_weekly_top()') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION award_previous_weekly_top() SET search_path=public,pg_temp';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION award_previous_weekly_top() FROM PUBLIC,anon,authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION award_previous_weekly_top() TO service_role';
  END IF;
  IF to_regprocedure('revert_linktop_earnings()') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION revert_linktop_earnings() FROM PUBLIC,anon,authenticated';
  END IF;
END $$;

COMMIT;
