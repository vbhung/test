-- Plan.Database — Schema Supabase
-- Chạy script này trong SQL Editor của Supabase

-- 1. `profiles`
CREATE TABLE profiles (
  id               UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username         TEXT UNIQUE NOT NULL,
  display_name     TEXT NOT NULL,
  email_canonical  TEXT UNIQUE NOT NULL,
  cam_balance      NUMERIC(12,4) NOT NULL DEFAULT 0,
  cam_total_earned NUMERIC(12,4) NOT NULL DEFAULT 0,
  referral_code    TEXT UNIQUE NOT NULL,
  referred_by      UUID REFERENCES profiles(id),
  avatar_url       TEXT,
  role             TEXT NOT NULL DEFAULT 'user',
  is_banned        BOOLEAN NOT NULL DEFAULT FALSE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_current_user_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = auth.uid()
      AND role = 'admin'
  );
$$;

CREATE OR REPLACE FUNCTION public.is_valid_profile_self_update(
  p_id UUID,
  p_username TEXT,
  p_email_canonical TEXT,
  p_cam_balance NUMERIC,
  p_cam_total_earned NUMERIC,
  p_referral_code TEXT,
  p_referred_by UUID,
  p_role TEXT,
  p_is_banned BOOLEAN,
  p_created_at TIMESTAMPTZ
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles existing_profile
    WHERE existing_profile.id = auth.uid()
      AND existing_profile.id = p_id
      AND existing_profile.username = p_username
      AND existing_profile.email_canonical = p_email_canonical
      AND existing_profile.cam_balance = p_cam_balance
      AND existing_profile.cam_total_earned = p_cam_total_earned
      AND existing_profile.referral_code = p_referral_code
      AND existing_profile.referred_by IS NOT DISTINCT FROM p_referred_by
      AND existing_profile.role = p_role
      AND existing_profile.is_banned = p_is_banned
      AND existing_profile.created_at = p_created_at
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_current_user_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_valid_profile_self_update(UUID, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, UUID, TEXT, BOOLEAN, TIMESTAMPTZ) TO authenticated;

CREATE POLICY "Self profile view" ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Admin profile view" ON profiles FOR SELECT USING (public.is_current_user_admin());
CREATE POLICY "Self update profile" ON profiles FOR UPDATE USING (auth.uid() = id) WITH CHECK (
  auth.uid() = id
  AND public.is_valid_profile_self_update(
    id,
    username,
    email_canonical,
    cam_balance,
    cam_total_earned,
    referral_code,
    referred_by,
    role,
    is_banned,
    created_at
  )
);
CREATE POLICY "Admin profile manage" ON profiles FOR ALL USING (public.is_current_user_admin()) WITH CHECK (public.is_current_user_admin());

-- 2. `email_registry`
CREATE TABLE email_registry (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_email     TEXT UNIQUE NOT NULL,
  registered_user_id  UUID NOT NULL REFERENCES profiles(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE email_registry ENABLE ROW LEVEL SECURITY;

CREATE TYPE registration_limit_status AS ENUM ('pending', 'confirmed');

CREATE TABLE registration_limits (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  ip_hash      TEXT UNIQUE NOT NULL,
  device_hash  TEXT UNIQUE NOT NULL,
  status       registration_limit_status NOT NULL DEFAULT 'pending',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE registration_limits ENABLE ROW LEVEL SECURITY;

-- 3. `link_verifications`
CREATE TYPE link_status AS ENUM ('pending', 'used', 'expired');

CREATE TABLE link_verifications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT UNIQUE NOT NULL,
  reward_cam  NUMERIC(8,4) NOT NULL,
  status      link_status NOT NULL DEFAULT 'pending',
  used_by     UUID REFERENCES profiles(id),
  used_at     TIMESTAMPTZ,
  expires_at  TIMESTAMPTZ NOT NULL,
  created_by  UUID REFERENCES profiles(id),
  metadata    JSONB DEFAULT '{}',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_link_verifications_code ON link_verifications(code);
CREATE INDEX idx_link_verifications_status ON link_verifications(status);

ALTER TABLE link_verifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Used links" ON link_verifications FOR SELECT USING (auth.uid() = used_by);

-- 4. `cam_transactions`
CREATE TYPE cam_tx_type AS ENUM (
  'earn', 'transfer_in', 'transfer_out', 'fee', 'redeem', 'referral_bonus', 'admin_adjust', 'admin_adjust_add', 'admin_adjust_sub'
);

CREATE TABLE cam_transactions (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES profiles(id),
  type           cam_tx_type NOT NULL,
  amount         NUMERIC(12,4) NOT NULL CHECK (amount > 0),
  balance_before NUMERIC(12,4) NOT NULL,
  balance_after  NUMERIC(12,4) NOT NULL,
  ref_id         UUID,
  description    TEXT NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cam_tx_user_id ON cam_transactions(user_id);
CREATE INDEX idx_cam_tx_created_at ON cam_transactions(created_at DESC);
CREATE INDEX idx_cam_tx_type ON cam_transactions(type);

ALTER TABLE cam_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own transactions" ON cam_transactions FOR SELECT USING (auth.uid() = user_id);

-- CPX survey postback audit + idempotency
CREATE TABLE survey_postbacks (
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

CREATE INDEX idx_survey_postbacks_user_id ON survey_postbacks(user_id);
CREATE INDEX idx_survey_postbacks_created_at ON survey_postbacks(created_at DESC);

ALTER TABLE survey_postbacks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own survey postbacks" ON survey_postbacks FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Admin survey postbacks" ON survey_postbacks FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles admin_profiles WHERE admin_profiles.id = auth.uid() AND admin_profiles.role = 'admin')
) WITH CHECK (
  EXISTS (SELECT 1 FROM profiles admin_profiles WHERE admin_profiles.id = auth.uid() AND admin_profiles.role = 'admin')
);

-- 5. `transfers`
CREATE TYPE transfer_status AS ENUM ('completed', 'failed');

CREATE TABLE transfers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id   UUID NOT NULL REFERENCES profiles(id),
  receiver_id UUID NOT NULL REFERENCES profiles(id),
  amount      NUMERIC(12,4) NOT NULL CHECK (amount > 0),
  fee         NUMERIC(8,4) NOT NULL DEFAULT 0.25,
  note        TEXT CHECK (char_length(note) <= 100),
  status      transfer_status NOT NULL DEFAULT 'completed',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT different_users CHECK (sender_id != receiver_id)
);

CREATE INDEX idx_transfers_sender ON transfers(sender_id);
CREATE INDEX idx_transfers_receiver ON transfers(receiver_id);

ALTER TABLE transfers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own transfers" ON transfers FOR SELECT USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

-- 6. `redemptions`
CREATE TYPE redeem_type AS ENUM ('phone_card', 'game_card', 'bank', 'game_topup');
CREATE TYPE redeem_status AS ENUM ('pending', 'processing', 'completed', 'rejected');

CREATE TABLE redemptions (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES profiles(id),
  type         redeem_type NOT NULL,
  amount_cam   NUMERIC(12,4) NOT NULL CHECK (amount_cam > 0),
  amount_vnd   NUMERIC(15,0) NOT NULL,
  status       redeem_status NOT NULL DEFAULT 'pending',
  details      JSONB NOT NULL DEFAULT '{}',
  admin_note   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ
);

CREATE INDEX idx_redemptions_user_id ON redemptions(user_id);
CREATE INDEX idx_redemptions_status ON redemptions(status);

ALTER TABLE redemptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own redemptions" ON redemptions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Admin redemptions view" ON redemptions FOR SELECT USING (
  EXISTS (SELECT 1 FROM profiles admin_profiles WHERE admin_profiles.id = auth.uid() AND admin_profiles.role = 'admin')
);
CREATE POLICY "Admin redemptions update" ON redemptions FOR UPDATE USING (
  EXISTS (SELECT 1 FROM profiles admin_profiles WHERE admin_profiles.id = auth.uid() AND admin_profiles.role = 'admin')
) WITH CHECK (
  EXISTS (SELECT 1 FROM profiles admin_profiles WHERE admin_profiles.id = auth.uid() AND admin_profiles.role = 'admin')
);

-- 7. `referral_earnings`
CREATE TABLE referral_earnings (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id    UUID NOT NULL REFERENCES profiles(id),
  referee_id     UUID NOT NULL REFERENCES profiles(id),
  tx_id          UUID NOT NULL REFERENCES cam_transactions(id),
  amount         NUMERIC(12,4) NOT NULL CHECK (amount > 0),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE referral_earnings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own earnings" ON referral_earnings FOR SELECT USING (auth.uid() = referrer_id);

-- 8. `notifications`
CREATE TABLE notifications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES profiles(id),
  title       TEXT NOT NULL,
  body        TEXT NOT NULL,
  is_read     BOOLEAN NOT NULL DEFAULT FALSE,
  metadata    JSONB DEFAULT '{}',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own notifications" ON notifications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Mark read" ON notifications FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (
  auth.uid() = user_id
  AND title = (SELECT title FROM notifications WHERE id = notifications.id)
  AND body = (SELECT body FROM notifications WHERE id = notifications.id)
);

-- 9. `security_flags` & `admin_audit_log`
CREATE TABLE security_flags (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES profiles(id),
  reason     TEXT NOT NULL,
  metadata   JSONB DEFAULT '{}',
  reviewed   BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_security_flags_user ON security_flags(user_id, created_at DESC);
ALTER TABLE security_flags ENABLE ROW LEVEL SECURITY;

CREATE TABLE admin_audit_log (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id   UUID NOT NULL REFERENCES profiles(id),
  action     TEXT NOT NULL,
  target_id  UUID,
  target_data JSONB,
  ip         TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE admin_audit_log ENABLE ROW LEVEL SECURITY;
-- ==========================================
-- HỆ THỐNG KIẾM CAM QUA LINK RÚT GỌN
-- ==========================================

-- 1. Bảng lưu trữ danh sách Nhà cung cấp (Providers)
CREATE TABLE earn_providers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    code TEXT UNIQUE NOT NULL,
    api_url TEXT NOT NULL,
    api_token TEXT NOT NULL,
    reward_cam NUMERIC(8,4) NOT NULL DEFAULT 1.0,
    daily_limit INTEGER NOT NULL DEFAULT 2,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Bật RLS cho earn_providers (Chỉ Admin đọc/sửa trực tiếp; user thường lấy danh sách qua API server)
ALTER TABLE earn_providers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admin có toàn quyền trên providers" ON earn_providers FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
);

-- 2. Bảng lưu trữ phiên làm nhiệm vụ (Earn Tasks)
CREATE TYPE earn_task_status AS ENUM ('pending', 'completed', 'rejected');

CREATE TABLE earn_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES profiles(id) NOT NULL,
    provider_code TEXT REFERENCES earn_providers(code) NOT NULL,
    token TEXT UNIQUE NOT NULL,
    shortened_url TEXT NOT NULL,
    status earn_task_status NOT NULL DEFAULT 'pending',
    reward_cam NUMERIC(8,4) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index để tối ưu query
CREATE INDEX idx_earn_tasks_user_id ON earn_tasks(user_id);
CREATE INDEX idx_earn_tasks_token ON earn_tasks(token);

-- Bật RLS cho earn_tasks
ALTER TABLE earn_tasks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "User có thể xem task của chính mình" ON earn_tasks FOR SELECT USING (auth.uid() = user_id);

-- 3. Cập nhật ENUM cam_tx_type cho 'earn_task' nếu chưa có (không cần nếu bạn dùng 'earn' chung, hiện tại DB đang có 'earn')
-- ALTER TYPE cam_tx_type ADD VALUE IF NOT EXISTS 'earn_task';

-- 4. Thêm dữ liệu mẫu ban đầu: Nhà cung cấp Link4M
INSERT INTO earn_providers (name, code, api_url, api_token, reward_cam, daily_limit, is_active)
VALUES (
    'Link4M',
    'link4m',
    'https://link4m.co/api-shorten/v2',
    'REPLACE_WITH_PROVIDER_TOKEN',
    1.0,
    2,
    true
) ON CONFLICT (code) DO NOTHING;

INSERT INTO earn_providers (name, code, api_url, api_token, reward_cam, daily_limit, is_active)
VALUES (
    'Layma',
    'layma',
    'https://api.layma.net/api/admin/shortlink/quicklink',
    'REPLACE_WITH_LAYMA_TOKEN',
    1.0,
    2,
    true
) ON CONFLICT (code) DO NOTHING;

INSERT INTO earn_providers (name, code, api_url, api_token, reward_cam, daily_limit, is_active)
VALUES (
    'Site2S',
    'site2s',
    'https://site2s.com/api',
    'REPLACE_WITH_SITE2S_TOKEN',
    1.0,
    3,
    true
) ON CONFLICT (code) DO NOTHING;

INSERT INTO earn_providers (name, code, api_url, api_token, reward_cam, daily_limit, is_active)
VALUES
    ('Uptolink Social', 'uptolink_social', 'https://uptolink.vip/api', 'REPLACE_WITH_UPTOLINK_TOKEN', 1.2, 1000, true),
    ('Uptolink Search 2 Step', 'uptolink_search_2step', 'https://uptolink.vip/api', 'REPLACE_WITH_UPTOLINK_TOKEN', 1.2, 1000, true),
    ('Uptolink Search 3 Step', 'uptolink_search_3step', 'https://uptolink.vip/api', 'REPLACE_WITH_UPTOLINK_TOKEN', 2.0, 1000, true),
    ('Uptolink Search 4 Step', 'uptolink_search_4step', 'https://uptolink.vip/api', 'REPLACE_WITH_UPTOLINK_TOKEN', 2.0, 1000, true)
ON CONFLICT (code) DO NOTHING;
