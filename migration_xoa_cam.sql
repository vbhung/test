-- ==========================================================
-- 1. Add new transaction types for cam revoke / restore
-- ==========================================================

ALTER TYPE cam_tx_type ADD VALUE IF NOT EXISTS 'earn_revoke';
ALTER TYPE cam_tx_type ADD VALUE IF NOT EXISTS 'earn_restore';

-- ==========================================================
-- 2. Batch table to track revoke operations (for "hoàn")
-- ==========================================================

CREATE TABLE IF NOT EXISTS cam_revoke_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source TEXT NOT NULL CHECK (source IN ('nhapma', 'layma')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'restored')),
  total_cam NUMERIC(12,4) NOT NULL DEFAULT 0,
  user_count INTEGER NOT NULL DEFAULT 0,
  details JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  restored_at TIMESTAMPTZ,
  restored_by UUID REFERENCES profiles(id)
);

ALTER TABLE cam_revoke_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins full access" ON cam_revoke_batches FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

-- ==========================================================
-- 3. admin_revoke_source_cam: deduct all cam earned from a source
--    Balance can go negative (users who already spent it).
--    Records a batch so it can be restored later.
-- ==========================================================

CREATE OR REPLACE FUNCTION admin_revoke_source_cam(p_source TEXT, p_admin_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_batch_id UUID;
  v_total NUMERIC(12,4) := 0;
  v_count INTEGER := 0;
  v_details JSONB := '[]'::jsonb;
  v_rec RECORD;
  v_balance NUMERIC(12,4);
  v_new_balance NUMERIC(12,4);
  v_desc TEXT;
BEGIN
  IF p_source NOT IN ('nhapma', 'layma') THEN
    RAISE EXCEPTION 'INVALID_SOURCE';
  END IF;

  IF EXISTS (SELECT 1 FROM cam_revoke_batches WHERE source = p_source AND status = 'active') THEN
    RAISE EXCEPTION 'ACTIVE_BATCH_EXISTS';
  END IF;

  v_desc := 'Hệ thống tự trừ cam lý do ' || p_source || ' ngưng duyệt/đóng cửa';

  INSERT INTO cam_revoke_batches (source, created_by)
  VALUES (p_source, p_admin_id)
  RETURNING id INTO v_batch_id;

  FOR v_rec IN
    SELECT user_id, SUM(amount) AS total
    FROM cam_transactions
    WHERE type = 'earn'
      AND description ILIKE '%(' || p_source || ')%'
    GROUP BY user_id
    HAVING SUM(amount) > 0
  LOOP
    SELECT cam_balance INTO v_balance FROM profiles WHERE id = v_rec.user_id FOR UPDATE;
    v_new_balance := v_balance - v_rec.total;

    UPDATE profiles SET cam_balance = v_new_balance, updated_at = NOW() WHERE id = v_rec.user_id;

    INSERT INTO cam_transactions (user_id, type, amount, balance_before, balance_after, description, ref_id)
    VALUES (v_rec.user_id, 'earn_revoke', v_rec.total, v_balance, v_new_balance, v_desc, v_batch_id);

    v_details := v_details || jsonb_build_object('user_id', v_rec.user_id, 'amount', v_rec.total);
    v_total := v_total + v_rec.total;
    v_count := v_count + 1;
  END LOOP;

  UPDATE cam_revoke_batches
  SET total_cam = v_total, user_count = v_count, details = v_details
  WHERE id = v_batch_id;

  RETURN jsonb_build_object('batch_id', v_batch_id, 'user_count', v_count, 'total_cam', v_total);
END;
$$;

-- ==========================================================
-- 4. admin_restore_source_cam: add back the deducted cam ("hoàn")
-- ==========================================================

CREATE OR REPLACE FUNCTION admin_restore_source_cam(p_batch_id UUID, p_admin_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_batch cam_revoke_batches%ROWTYPE;
  v_item RECORD;
  v_balance NUMERIC(12,4);
  v_new_balance NUMERIC(12,4);
  v_total NUMERIC(12,4) := 0;
  v_count INTEGER := 0;
BEGIN
  SELECT * INTO v_batch FROM cam_revoke_batches WHERE id = p_batch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BATCH_NOT_FOUND'; END IF;
  IF v_batch.status <> 'active' THEN RAISE EXCEPTION 'BATCH_ALREADY_RESTORED'; END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_batch.details)
  LOOP
    SELECT cam_balance INTO v_balance FROM profiles WHERE id = (v_item.value->>'user_id')::uuid FOR UPDATE;
    v_new_balance := v_balance + (v_item.value->>'amount')::numeric;

    UPDATE profiles SET cam_balance = v_new_balance, updated_at = NOW() WHERE id = (v_item.value->>'user_id')::uuid;

    INSERT INTO cam_transactions (user_id, type, amount, balance_before, balance_after, description, ref_id)
    VALUES (
      (v_item.value->>'user_id')::uuid,
      'earn_restore',
      (v_item.value->>'amount')::numeric,
      v_balance,
      v_new_balance,
      'Hệ thống hoàn trả cam lý do ' || v_batch.source || ' ngưng duyệt/đóng cửa',
      p_batch_id
    );

    v_total := v_total + (v_item.value->>'amount')::numeric;
    v_count := v_count + 1;
  END LOOP;

  UPDATE cam_revoke_batches
  SET status = 'restored', restored_at = NOW(), restored_by = p_admin_id
  WHERE id = p_batch_id;

  RETURN jsonb_build_object('batch_id', p_batch_id, 'user_count', v_count, 'total_cam', v_total);
END;
$$;

-- ==========================================================
-- 5. admin_delete_revoke_batch: permanently delete the restore
--    cache so the cam can never be restored again ("xóa hẳn")
-- ==========================================================

CREATE OR REPLACE FUNCTION admin_delete_revoke_batch(p_batch_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_batch cam_revoke_batches%ROWTYPE;
BEGIN
  SELECT * INTO v_batch FROM cam_revoke_batches WHERE id = p_batch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BATCH_NOT_FOUND'; END IF;
  IF v_batch.status <> 'active' THEN RAISE EXCEPTION 'BATCH_ALREADY_RESTORED'; END IF;

  DELETE FROM cam_revoke_batches WHERE id = p_batch_id;

  RETURN jsonb_build_object('batch_id', p_batch_id, 'source', v_batch.source);
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_revoke_source_cam(TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION admin_restore_source_cam(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION admin_delete_revoke_batch(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_revoke_source_cam(TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION admin_restore_source_cam(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION admin_delete_revoke_batch(UUID) TO service_role;
