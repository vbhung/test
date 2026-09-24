-- Run this in Supabase SQL Editor
-- Tạo function lấy tổng tiền đã thanh toán (bank + card)

CREATE OR REPLACE FUNCTION get_paid_redemption_stats()
RETURNS JSONB AS $$
DECLARE
  v_card_paid NUMERIC(15,0) := 0;
  v_bank_paid NUMERIC(15,0) := 0;
BEGIN
  SELECT COALESCE(SUM(amount_vnd), 0)
    INTO v_card_paid
  FROM redemptions
  WHERE status = 'completed'
    AND type IN ('phone_card', 'game_card');

  SELECT COALESCE(SUM(amount_vnd), 0)
    INTO v_bank_paid
  FROM redemptions
  WHERE status = 'completed'
    AND type = 'bank';

  RETURN jsonb_build_object(
    'total_paid_vnd', v_card_paid + v_bank_paid,
    'card_paid_vnd', v_card_paid,
    'bank_paid_vnd', v_bank_paid
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
