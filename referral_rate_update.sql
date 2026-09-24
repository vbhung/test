-- Run this in Supabase SQL Editor to apply the new referral commission tiers.
CREATE OR REPLACE FUNCTION get_referral_commission_rate(
  p_referrer_id UUID,
  p_referee_id UUID
) RETURNS NUMERIC(4,2) AS $$
DECLARE
  v_rank INTEGER;
BEGIN
  SELECT COUNT(*) + 1 INTO v_rank
  FROM profiles
  WHERE referred_by = p_referrer_id
    AND created_at < (SELECT created_at FROM profiles WHERE id = p_referee_id);

  IF v_rank IS NULL OR v_rank < 1 THEN
    v_rank := 1;
  END IF;

  IF v_rank <= 1 THEN RETURN 0.15;
  ELSIF v_rank = 2 THEN RETURN 0.13;
  ELSIF v_rank <= 4 THEN RETURN 0.10;
  ELSIF v_rank <= 9 THEN RETURN 0.07;
  ELSIF v_rank <= 19 THEN RETURN 0.05;
  ELSIF v_rank <= 49 THEN RETURN 0.02;
  ELSE RETURN 0.01;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
