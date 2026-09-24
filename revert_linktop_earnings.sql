-- ============================================================
-- revert_linktop_earnings()
-- Hoan tra toan bo Cam ma nguoi dung da nhan tu Uptolink/Octolink/Linktop
-- Giam cam_balance + cam_total_earned, ghi vao lich su giao dich
-- ============================================================
CREATE OR REPLACE FUNCTION revert_linktop_earnings()
RETURNS TABLE(affected_users BIGINT, total_cam_reverted NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_user RECORD;
  v_total_deducted NUMERIC := 0;
  v_user_count BIGINT := 0;
  v_balance_before NUMERIC(12,4);
  v_balance_after NUMERIC(12,4);
  v_total_earned_before NUMERIC(12,4);
  v_total_earned_after NUMERIC(12,4);
  v_amount NUMERIC(12,4);
BEGIN
  FOR v_user IN
    SELECT
      ct.user_id,
      SUM(ct.amount)::NUMERIC(12,4) AS total_earned
    FROM cam_transactions ct
    WHERE ct.type = 'earn'
      AND (ct.description LIKE 'Vuot link (uptolink\_%' ESCAPE '\'
        OR ct.description = 'Vuot link (linktop)')
    GROUP BY ct.user_id
    HAVING SUM(ct.amount) > 0
  LOOP
    SELECT p.cam_balance, p.cam_total_earned
      INTO v_balance_before, v_total_earned_before
    FROM profiles p
    WHERE p.id = v_user.user_id
    FOR UPDATE;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_amount := LEAST(v_user.total_earned, v_balance_before);
    IF v_amount <= 0 THEN
      CONTINUE;
    END IF;

    v_balance_after := v_balance_before - v_amount;
    v_total_earned_after := GREATEST(v_total_earned_before - v_amount, 0);

    UPDATE profiles
    SET
      cam_balance = v_balance_after,
      cam_total_earned = v_total_earned_after,
      updated_at = NOW()
    WHERE id = v_user.user_id;

    INSERT INTO cam_transactions (user_id, type, amount, balance_before, balance_after, description)
    VALUES (
      v_user.user_id,
      'admin_adjust_sub',
      v_amount,
      v_balance_before,
      v_balance_after,
      'Bên linktop gặp vấn đề'
    );

    v_total_deducted := v_total_deducted + v_amount;
    v_user_count := v_user_count + 1;
  END LOOP;

  RETURN QUERY SELECT v_user_count, v_total_deducted;
END;
$$;
