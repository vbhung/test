CREATE TABLE IF NOT EXISTS global_notifications (
  id        INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  content   TEXT NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE global_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin full access on global_notifications" ON global_notifications;
CREATE POLICY "Admin full access on global_notifications"
ON global_notifications FOR ALL
USING (
  EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
);

DROP POLICY IF EXISTS "Public read global_notifications" ON global_notifications;
CREATE POLICY "Public read global_notifications"
ON global_notifications FOR SELECT
USING (true);

INSERT INTO global_notifications (id, content) VALUES (1, '') ON CONFLICT (id) DO NOTHING;
