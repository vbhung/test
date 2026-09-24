-- ==========================================================
-- Cancel ALL pending redemptions with full refund (no fee)
-- ==========================================================

CREATE OR REPLACE FUNCTION cancel_all_pending_redemptions(
  p_ticket_ids UUID[],
  p_admin_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count INTEGER := 0;
  v_refunded NUMERIC(12,4) := 0;
  v_ticket_id UUID;
BEGIN
  FOREACH v_ticket_id IN ARRAY p_ticket_ids
  LOOP
    BEGIN
      PERFORM process_redemption_decision(v_ticket_id, 'rejected', p_admin_note, FALSE);
      v_count := v_count + 1;
      SELECT COALESCE(v_refunded, 0) + COALESCE((
        SELECT amount_cam FROM redemptions WHERE id = v_ticket_id
      ), 0) INTO v_refunded;
    EXCEPTION WHEN OTHERS THEN
      -- skip tickets already processed or invalid
      CONTINUE;
    END;
  END LOOP;

  RETURN jsonb_build_object('canceled', v_count, 'refunded_cam', v_refunded);
END;
$$;

REVOKE EXECUTE ON FUNCTION cancel_all_pending_redemptions(UUID[], TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cancel_all_pending_redemptions(UUID[], TEXT) TO service_role;
