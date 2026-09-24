-- Hotfix for award_previous_weekly_top when ROW_NUMBER() rank is bigint.
-- Run this once if /api/weekly-top/status returns:
-- function weekly_top_reward_for_rank(bigint) does not exist

CREATE OR REPLACE FUNCTION weekly_top_reward_for_rank(p_rank BIGINT)
RETURNS NUMERIC AS $$
BEGIN
  RETURN CASE
    WHEN p_rank = 1 THEN 20
    WHEN p_rank = 2 THEN 16
    WHEN p_rank = 3 THEN 12
    WHEN p_rank = 4 THEN 8
    WHEN p_rank IN (5, 6) THEN 4
    WHEN p_rank BETWEEN 7 AND 10 THEN 2
    ELSE 0
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
