-- Weekly earn-task leaderboard and automatic weekly rewards.
-- Run this in Supabase SQL Editor before enabling /dashboard/top.

CREATE TABLE IF NOT EXISTS weekly_top_cache (
  period          TEXT NOT NULL,
  week_start_vn   DATE NOT NULL,
  week_end_vn     DATE NOT NULL,
  rank            INTEGER NOT NULL CHECK (rank BETWEEN 1 AND 10),
  user_id         UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  username        TEXT NOT NULL,
  display_name    TEXT NOT NULL,
  task_count      INTEGER NOT NULL DEFAULT 0,
  generated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (period, rank),
  UNIQUE (period, user_id)
);

CREATE INDEX IF NOT EXISTS idx_weekly_top_cache_period_rank ON weekly_top_cache(period, rank);
CREATE INDEX IF NOT EXISTS idx_weekly_top_cache_generated_at ON weekly_top_cache(generated_at DESC);

ALTER TABLE weekly_top_cache ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated weekly top cache view" ON weekly_top_cache;
CREATE POLICY "Authenticated weekly top cache view" ON weekly_top_cache
FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE TABLE IF NOT EXISTS weekly_top_refreshes (
  period        TEXT PRIMARY KEY,
  week_start_vn DATE NOT NULL,
  week_end_vn   DATE NOT NULL,
  generated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE weekly_top_refreshes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated weekly top refresh view" ON weekly_top_refreshes;
CREATE POLICY "Authenticated weekly top refresh view" ON weekly_top_refreshes
FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE TABLE IF NOT EXISTS weekly_top_rewards (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  period        TEXT NOT NULL,
  week_start_vn DATE NOT NULL,
  week_end_vn   DATE NOT NULL,
  user_id       UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  rank          INTEGER NOT NULL CHECK (rank BETWEEN 1 AND 10),
  task_count    INTEGER NOT NULL,
  reward_cam    NUMERIC(12,4) NOT NULL CHECK (reward_cam > 0),
  tx_id         UUID REFERENCES cam_transactions(id),
  awarded_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (period, user_id),
  UNIQUE (period, rank)
);

CREATE INDEX IF NOT EXISTS idx_weekly_top_rewards_user_id ON weekly_top_rewards(user_id);
CREATE INDEX IF NOT EXISTS idx_weekly_top_rewards_period ON weekly_top_rewards(period);

ALTER TABLE weekly_top_rewards ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own weekly top rewards" ON weekly_top_rewards;
CREATE POLICY "Own weekly top rewards" ON weekly_top_rewards
FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admin weekly top rewards" ON weekly_top_rewards;
CREATE POLICY "Admin weekly top rewards" ON weekly_top_rewards
FOR SELECT USING (
  EXISTS (
    SELECT 1
    FROM profiles admin_profiles
    WHERE admin_profiles.id = auth.uid()
      AND admin_profiles.role = 'admin'
  )
);

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

CREATE OR REPLACE FUNCTION refresh_weekly_top_current(p_force BOOLEAN DEFAULT FALSE)
RETURNS JSONB AS $$
DECLARE
  v_now_vn TIMESTAMP;
  v_week_start_vn TIMESTAMP;
  v_week_end_vn TIMESTAMP;
  v_week_start_utc TIMESTAMPTZ;
  v_week_end_utc TIMESTAMPTZ;
  v_period TEXT;
  v_latest_generated_at TIMESTAMPTZ;
BEGIN
  v_now_vn := timezone('Asia/Bangkok', NOW());
  v_week_start_vn := date_trunc('week', v_now_vn);
  v_week_end_vn := v_week_start_vn + INTERVAL '7 days';
  v_week_start_utc := v_week_start_vn AT TIME ZONE 'Asia/Bangkok';
  v_week_end_utc := v_week_end_vn AT TIME ZONE 'Asia/Bangkok';
  v_period := to_char(v_week_start_vn::DATE, 'IYYY-"W"IW');

  SELECT MAX(generated_at)
    INTO v_latest_generated_at
  FROM weekly_top_refreshes
  WHERE period = v_period;

  IF NOT p_force
     AND v_latest_generated_at IS NOT NULL
     AND v_latest_generated_at > NOW() - INTERVAL '216 minutes' THEN
    RETURN jsonb_build_object(
      'refreshed', false,
      'period', v_period,
      'generated_at', v_latest_generated_at
    );
  END IF;

  DELETE FROM weekly_top_cache WHERE period = v_period;

  INSERT INTO weekly_top_cache (
    period,
    week_start_vn,
    week_end_vn,
    rank,
    user_id,
    username,
    display_name,
    task_count,
    generated_at
  )
  SELECT
    v_period,
    v_week_start_vn::DATE,
    (v_week_end_vn::DATE - 1),
    ranked.rank,
    ranked.user_id,
    ranked.username,
    ranked.display_name,
    ranked.task_count,
    NOW()
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
      AND COALESCE(task.completed_at, task.created_at) >= v_week_start_utc
      AND COALESCE(task.completed_at, task.created_at) < v_week_end_utc
    GROUP BY task.user_id, referred.username, referred.display_name
  ) ranked
  WHERE ranked.rank <= 10;

  INSERT INTO weekly_top_refreshes (period, week_start_vn, week_end_vn, generated_at)
  VALUES (v_period, v_week_start_vn::DATE, (v_week_end_vn::DATE - 1), NOW())
  ON CONFLICT (period)
  DO UPDATE SET
    week_start_vn = EXCLUDED.week_start_vn,
    week_end_vn = EXCLUDED.week_end_vn,
    generated_at = EXCLUDED.generated_at;

  RETURN jsonb_build_object(
    'refreshed', true,
    'period', v_period,
    'generated_at', NOW()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
      v_tx_id := process_cam_transaction(
        v_row.user_id,
        'admin_adjust_add',
        v_row.reward_cam,
        'Thuong top vuot tuan ' || v_period || ' - Top ' || v_row.rank::TEXT,
        NULL
      );

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
