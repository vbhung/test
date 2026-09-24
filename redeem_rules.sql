-- Redemption gating rules.
-- Run this in Supabase SQL Editor to harden direct RPC calls.

CREATE OR REPLACE FUNCTION process_redemption_request(
  p_user_id UUID,
  p_type redeem_type,
  p_amount_cam NUMERIC(12,4),
  p_amount_vnd NUMERIC(15,0),
  p_details JSONB
) RETURNS UUID AS $$
DECLARE
  v_result JSONB;
  v_ticket_id UUID;
  v_latest_redeem_at TIMESTAMPTZ;
  v_used_free_card_redeems INTEGER := 0;
  v_required_referrals INTEGER := 0;
  v_qualified_referrals INTEGER := 0;
BEGIN
  SELECT created_at
    INTO v_latest_redeem_at
  FROM redemptions
  WHERE user_id = p_user_id
    AND status <> 'rejected'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_latest_redeem_at IS NOT NULL AND v_latest_redeem_at > NOW() - INTERVAL '12 hours' THEN
    RAISE EXCEPTION 'REDEEM_COOLDOWN';
  END IF;

  IF p_type IN ('phone_card', 'game_card') THEN
    SELECT COUNT(*)
      INTO v_used_free_card_redeems
    FROM redemptions
    WHERE user_id = p_user_id
      AND type IN ('phone_card', 'game_card')
      AND status <> 'rejected';
  END IF;

  IF p_type = 'bank' OR v_used_free_card_redeems >= 3 THEN
    v_required_referrals := CASE
      WHEN p_amount_vnd <= 50000 THEN 1
      WHEN p_amount_vnd <= 100000 THEN 3
      WHEN p_amount_vnd <= 500000 THEN 5
      ELSE 10
    END;

    SELECT COUNT(*)
      INTO v_qualified_referrals
    FROM profiles referred
    WHERE referred.referred_by = p_user_id
      AND EXISTS (
        SELECT 1
        FROM earn_tasks task
        WHERE task.user_id = referred.id
          AND task.status = 'completed'
      );

    IF v_qualified_referrals < v_required_referrals THEN
      RAISE EXCEPTION 'QUALIFIED_REFERRALS_REQUIRED:%:%', v_required_referrals, v_qualified_referrals;
    END IF;
  END IF;

  v_result := process_cam_transaction(
    p_user_id,
    'redeem',
    p_amount_cam,
    'Tao yeu cau rut thuong',
    NULL
  );

  INSERT INTO redemptions (user_id, type, amount_cam, amount_vnd, status, details)
  VALUES (p_user_id, p_type, p_amount_cam, p_amount_vnd, 'pending', COALESCE(p_details, '{}'::jsonb))
  RETURNING id INTO v_ticket_id;

  RETURN v_ticket_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
