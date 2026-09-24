-- Phienchoso providers + review queue system

ALTER TYPE cam_tx_type ADD VALUE IF NOT EXISTS 'earn_review_hold';
ALTER TYPE cam_tx_type ADD VALUE IF NOT EXISTS 'earn_review_release';

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
    v_referral_bonus := ROUND(p_amount * get_referral_commission_rate(v_referred_by, p_user_id), 4);

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

CREATE TABLE IF NOT EXISTS earn_review_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id),
    task_id UUID NOT NULL REFERENCES earn_tasks(id),
    provider_code TEXT NOT NULL,
    alias TEXT NOT NULL,
    total_cam NUMERIC(12,4) NOT NULL,
    advanced_cam NUMERIC(12,4) NOT NULL,
    pending_cam NUMERIC(12,4) NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    checked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    UNIQUE (task_id)
);

CREATE INDEX IF NOT EXISTS idx_earn_review_queue_status ON earn_review_queue(status);
CREATE INDEX IF NOT EXISTS idx_earn_review_queue_user ON earn_review_queue(user_id);

INSERT INTO earn_providers (name, code, api_url, api_token, reward_cam, daily_limit, is_active)
VALUES (
    'Phienchoso từ khóa',
    'phienchoso_tukhoa',
    'https://phienchoso.com/api_task/tukhoa-dev.php',
    'REPLACE_WITH_YOUR_PROVIDER_API_TOKEN',
    1.5,
    2,
    false
) ON CONFLICT (code) DO NOTHING;

INSERT INTO earn_providers (name, code, api_url, api_token, reward_cam, daily_limit, is_active)
VALUES (
    'Phienchoso review',
    'phienchoso_review',
    'https://phienchoso.com/api_task/review-dev.php',
    'REPLACE_WITH_YOUR_PROVIDER_API_TOKEN',
    3.0,
    2,
    false
) ON CONFLICT (code) DO NOTHING;
