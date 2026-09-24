-- CPX Research survey rewards support.
-- Run this once in Supabase SQL Editor before enabling the CPX postback.

CREATE TABLE IF NOT EXISTS survey_postbacks (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider       TEXT NOT NULL DEFAULT 'cpx',
  transaction_id TEXT NOT NULL,
  user_id        UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status         TEXT NOT NULL,
  amount_cam     NUMERIC(12,4),
  amount_usd     NUMERIC(12,4),
  raw_payload    JSONB NOT NULL DEFAULT '{}'::jsonb,
  credited_tx_id UUID REFERENCES cam_transactions(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (provider, transaction_id)
);

CREATE INDEX IF NOT EXISTS idx_survey_postbacks_user_id ON survey_postbacks(user_id);
CREATE INDEX IF NOT EXISTS idx_survey_postbacks_created_at ON survey_postbacks(created_at DESC);

ALTER TABLE survey_postbacks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own survey postbacks" ON survey_postbacks;
CREATE POLICY "Own survey postbacks" ON survey_postbacks
FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admin survey postbacks" ON survey_postbacks;
CREATE POLICY "Admin survey postbacks" ON survey_postbacks
FOR ALL USING (
  EXISTS (
    SELECT 1
    FROM profiles admin_profiles
    WHERE admin_profiles.id = auth.uid()
      AND admin_profiles.role = 'admin'
  )
) WITH CHECK (
  EXISTS (
    SELECT 1
    FROM profiles admin_profiles
    WHERE admin_profiles.id = auth.uid()
      AND admin_profiles.role = 'admin'
  )
);
