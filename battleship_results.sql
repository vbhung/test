-- Battleship results table
-- Chạy trong Supabase SQL Editor

CREATE TABLE IF NOT EXISTS battleship_results (
  id BIGSERIAL PRIMARY KEY,
  match_id TEXT UNIQUE NOT NULL,
  status TEXT NOT NULL DEFAULT 'finished',
  winner_id UUID REFERENCES auth.users(id),
  loser_id UUID REFERENCES auth.users(id),
  reason TEXT,
  wager_context_ids JSONB,
  replay_hash TEXT,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Index for idempotency check
CREATE INDEX IF NOT EXISTS idx_battleship_results_match_id ON battleship_results(match_id);

-- RLS: users chỉ xem kết quả của mình
ALTER TABLE battleship_results ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_view_own_battleship" ON battleship_results
  FOR SELECT USING (
    auth.uid() = winner_id OR auth.uid() = loser_id
  );

-- Service role bypass RLS (admin client)
