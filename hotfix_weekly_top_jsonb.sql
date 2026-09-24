-- Hotfix: JSONB -> UUID assignment fix for award_previous_weekly_top and process_bonus_claim
-- process_cam_transaction returns JSONB, NOT UUID.
-- Assigning JSONB to a UUID variable raises a runtime error.
-- Must extract the tx_id via ->>'tx_id'::UUID .

CREATE OR REPLACE FUNCTION award_previous_weekly_top()
RETURNS JSONB AS $$
DECLARE
  v_now_vn TIMESTAMP;
  v_week_start_vn TIMESTAMP;
  v_prev_start_vn TIMESTAMP;
  v_prev_end_vn TIMESTAMP;
  v_prev_start_utc TIMESTAMPTZ;
  v_prev_end_utc TIMESTAMPTZ;
  v_period TEXT;
  v_awarded_count INTEGER := 0;
  v_tx_id UUID;
  v_row RECORD;
BEGIN
  v_now_vn := timezone('Asia/Bangkok', NOW());
  v_week_start_vn := date_trunc('week', v_now_vn);
  v_prev_start_vn := v_week_start_vn - INTERVAL '7 days';
  v_prev_end_vn := v_week_start_vn;
  v_prev_start_utc := v_prev_start_vn AT TIME ZONE 'Asia/Bangkok';
  v_prev_end_utc := v_prev_end_vn AT TIME ZONE 'Asia/Bangkok';
  v_period := to_char(v_prev_start_vn::DATE, 'IYYY-"W"IW');

  FOR v_row IN
    SELECT
      ranked.rank,
      ranked.user_id,
      ranked.username,
      ranked.display_name,
      ranked.task_count,
      weekly_top_reward_for_rank(ranked.rank) AS reward_cam
    FROM (
      SELECT
        ROW_NUMBER() OVER (
          ORDER BY COUNT(*) DESC, MAX(COALESCE(task.completed_at, task.created_at)) ASC, referred.username ASC
        ) AS rank,
        task.user_id,
        referred.username,
        referred.display_name,
        COUNT(*)::INTEGER AS task_count
      FROM earn_tasks task
      JOIN profiles referred ON referred.id = task.user_id
      WHERE task.status = 'completed'
        AND COALESCE(task.completed_at, task.created_at) >= v_prev_start_utc
        AND COALESCE(task.completed_at, task.created_at) < v_prev_end_utc
      GROUP BY task.user_id, referred.username, referred.display_name
    ) ranked
    WHERE ranked.rank <= 10
      AND ranked.task_count > 5
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM weekly_top_rewards rewards
      WHERE rewards.period = v_period
        AND rewards.user_id = v_row.user_id
    ) THEN
      v_tx_id := (process_cam_transaction(
        v_row.user_id,
        'admin_adjust_add',
        v_row.reward_cam,
        'Thuong top vuot tuan ' || v_period || ' - Top ' || v_row.rank::TEXT,
        NULL
      ) ->> 'tx_id')::UUID;

      INSERT INTO weekly_top_rewards (
        period,
        week_start_vn,
        week_end_vn,
        user_id,
        rank,
        task_count,
        reward_cam,
        tx_id
      )
      VALUES (
        v_period,
        v_prev_start_vn::DATE,
        (v_prev_end_vn::DATE - 1),
        v_row.user_id,
        v_row.rank,
        v_row.task_count,
        v_row.reward_cam,
        v_tx_id
      );

      v_awarded_count := v_awarded_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('period', v_period, 'awarded_count', v_awarded_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
