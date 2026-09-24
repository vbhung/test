-- ==========================================================
-- 1. Redeem rules update
-- ==========================================================

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

  -- Card: always free, no referral check
  -- Bank: first 3 free, then check referrals
  IF p_type = 'bank' THEN
    SELECT COUNT(*) INTO v_used_free FROM redemptions
    WHERE user_id = p_user_id AND type = 'bank' AND status <> 'rejected';
    IF v_used_free >= 3 THEN
      v_required := CASE WHEN v_amount_vnd <= 50000 THEN 1 WHEN v_amount_vnd <= 100000 THEN 3
                         WHEN v_amount_vnd <= 500000 THEN 5 ELSE 10 END;
      SELECT COUNT(*) INTO v_qualified FROM profiles r
      WHERE r.referred_by = p_user_id AND EXISTS (
        SELECT 1 FROM earn_tasks t WHERE t.user_id = r.id AND t.status = 'completed');
      IF v_qualified < v_required THEN RAISE EXCEPTION 'QUALIFIED_REFERRALS_REQUIRED'; END IF;
    END IF;
  END IF;

  PERFORM process_cam_transaction(p_user_id, 'redeem', v_amount_cam, 'Tao yeu cau rut thuong', NULL);
  INSERT INTO redemptions(user_id,type,amount_cam,amount_vnd,status,details)
  VALUES(p_user_id,p_type,v_amount_cam,v_amount_vnd,'pending',COALESCE(p_details,'{}'::jsonb))
  RETURNING id INTO v_ticket_id;
  RETURN jsonb_build_object('ticket_id',v_ticket_id,'amount_cam',v_amount_cam,'amount_vnd',v_amount_vnd);
END;
$$;

REVOKE EXECUTE ON FUNCTION process_redemption_request_secure(UUID,redeem_type,NUMERIC,TEXT,NUMERIC,JSONB) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION process_redemption_request_secure(UUID,redeem_type,NUMERIC,TEXT,NUMERIC,JSONB) TO service_role;

-- ==========================================================
-- 2. Referral anti-abuse: suspension table
-- ==========================================================

CREATE TABLE IF NOT EXISTS referral_suspensions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'suspended' CHECK (status IN ('suspended', 'probation', 'active')),
  probation_started_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id)
);

ALTER TABLE referral_suspensions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins full access" ON referral_suspensions FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

-- ==========================================================
-- 3. Update process_cam_transaction to skip bonus if suspended
-- ==========================================================

CREATE OR REPLACE FUNCTION process_cam_transaction(
  p_user_id UUID,
  p_type TEXT,
  p_amount NUMERIC(12,4),
  p_description TEXT,
  p_ref_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_balance_before NUMERIC(12,4);
  v_balance_after NUMERIC(12,4);
  v_tx_id UUID;
  v_referred_by UUID;
  v_referral_bonus NUMERIC(12,4);
  v_actual_amount NUMERIC(12,4);
BEGIN
  SELECT cam_balance, referred_by
    INTO v_balance_before, v_referred_by
  FROM profiles
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'USER_PROFILE_NOT_FOUND';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT';
  END IF;

  v_actual_amount := p_amount;

  IF p_type IN ('earn', 'transfer_in', 'referral_bonus', 'admin_adjust_add', 'earn_review_release') THEN
    v_balance_after := v_balance_before + v_actual_amount;
  ELSIF p_type IN ('transfer_out', 'fee', 'redeem', 'admin_adjust_sub', 'earn_review_hold') THEN
    IF v_balance_before < p_amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_BALANCE';
    END IF;
    v_balance_after := v_balance_before - p_amount;
  ELSE
    RAISE EXCEPTION 'INVALID_TRANSACTION_TYPE';
  END IF;

  UPDATE profiles
  SET
    cam_balance = v_balance_after,
    cam_total_earned = CASE
      WHEN p_type IN ('earn', 'referral_bonus', 'admin_adjust_add') THEN cam_total_earned + v_actual_amount
      ELSE cam_total_earned
    END,
    updated_at = NOW()
  WHERE id = p_user_id;

  INSERT INTO cam_transactions (
    user_id,
    type,
    amount,
    balance_before,
    balance_after,
    description,
    ref_id
  ) VALUES (
    p_user_id,
    p_type::cam_tx_type,
    v_actual_amount,
    v_balance_before,
    v_balance_after,
    p_description,
    p_ref_id
  ) RETURNING id INTO v_tx_id;

  IF p_type = 'earn' AND v_referred_by IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM referral_suspensions WHERE user_id = v_referred_by AND status = 'suspended') THEN
      v_referral_bonus := 0;
    ELSE
      v_referral_bonus := ROUND(p_amount * get_referral_commission_rate(v_referred_by, p_user_id), 4);
    END IF;

    IF v_referral_bonus > 0 THEN
      PERFORM process_cam_transaction(
        v_referred_by,
        'referral_bonus',
        v_referral_bonus,
        'Hoa hong gioi thieu tu thanh vien cap duoi',
        v_tx_id
      );

      INSERT INTO referral_earnings (referrer_id, referee_id, tx_id, amount)
      VALUES (v_referred_by, p_user_id, v_tx_id, v_referral_bonus);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'tx_id', v_tx_id,
    'new_balance', v_balance_after
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ==========================================================
-- 4. process_referral_suspensions RPC (called by cron)
-- ==========================================================

CREATE OR REPLACE FUNCTION process_referral_suspensions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_referrer RECORD;
  v_total_tasks BIGINT;
  v_recent_tasks BIGINT;
BEGIN
  FOR v_referrer IN
    SELECT DISTINCT p.id, p.referred_by
    FROM profiles p
    WHERE p.referred_by IS NOT NULL
  LOOP
    SELECT COUNT(*) INTO v_recent_tasks
    FROM earn_tasks t
    JOIN profiles r ON r.id = t.user_id
    WHERE r.referred_by = v_referrer.id
      AND t.status = 'completed'
      AND t.completed_at > NOW() - INTERVAL '3 days';

    SELECT COUNT(*) INTO v_total_tasks
    FROM earn_tasks t
    JOIN profiles r ON r.id = t.user_id
    WHERE r.referred_by = v_referrer.id
      AND t.status = 'completed';

    IF v_recent_tasks = 0 AND EXISTS (
      SELECT 1 FROM profiles WHERE referred_by = v_referrer.id
    ) THEN
      INSERT INTO referral_suspensions (user_id, status)
      VALUES (v_referrer.id, 'suspended')
      ON CONFLICT (user_id) DO UPDATE SET
        status = CASE
          WHEN referral_suspensions.status = 'active' THEN 'suspended'
          ELSE referral_suspensions.status
        END,
        updated_at = NOW();

    ELSIF v_total_tasks >= 3 THEN
      INSERT INTO referral_suspensions (user_id, status, probation_started_at)
      VALUES (v_referrer.id, 'probation', NOW())
      ON CONFLICT (user_id) DO UPDATE SET
        status = CASE
          WHEN referral_suspensions.status IN ('suspended', 'probation') THEN 'probation'
          ELSE referral_suspensions.status
        END,
        probation_started_at = CASE
          WHEN referral_suspensions.status IN ('suspended', 'probation') THEN NOW()
          ELSE referral_suspensions.probation_started_at
        END,
        updated_at = NOW();
    END IF;
  END LOOP;

  -- Move probation -> active after 4 days
  UPDATE referral_suspensions
  SET status = 'active', updated_at = NOW()
  WHERE status = 'probation'
    AND probation_started_at IS NOT NULL
    AND probation_started_at < NOW() - INTERVAL '4 days';

  -- Clean up: remove users who no longer refer anyone
  DELETE FROM referral_suspensions rs
  WHERE NOT EXISTS (SELECT 1 FROM profiles WHERE referred_by = rs.user_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION process_referral_suspensions() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION process_referral_suspensions() TO service_role;
