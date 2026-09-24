-- security_hardening.sql
-- Apply this in Supabase SQL editor before deploying the hardened app code.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'registration_limit_status'
  ) THEN
    CREATE TYPE registration_limit_status AS ENUM ('pending', 'confirmed');
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_enum
    WHERE enumlabel = 'admin_adjust_add'
      AND enumtypid = 'cam_tx_type'::regtype
  ) THEN
    ALTER TYPE cam_tx_type ADD VALUE 'admin_adjust_add';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_enum
    WHERE enumlabel = 'admin_adjust_sub'
      AND enumtypid = 'cam_tx_type'::regtype
  ) THEN
    ALTER TYPE cam_tx_type ADD VALUE 'admin_adjust_sub';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_enum
    WHERE enumlabel = 'rejected'
      AND enumtypid = 'earn_task_status'::regtype
  ) THEN
    ALTER TYPE earn_task_status ADD VALUE 'rejected';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS registration_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  ip_hash TEXT NOT NULL UNIQUE,
  device_hash TEXT NOT NULL UNIQUE,
  status registration_limit_status NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE registration_limits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public profile view" ON profiles;
DROP POLICY IF EXISTS "Self profile view" ON profiles;
DROP POLICY IF EXISTS "Admin profile view" ON profiles;
DROP POLICY IF EXISTS "Self update profile" ON profiles;
DROP POLICY IF EXISTS "Admin profile manage" ON profiles;

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

CREATE POLICY "Self profile view"
ON profiles FOR SELECT
USING (auth.uid() = id);

CREATE POLICY "Admin profile view"
ON profiles FOR SELECT
USING (public.is_current_user_admin());

CREATE POLICY "Self update profile"
ON profiles FOR UPDATE
USING (auth.uid() = id)
WITH CHECK (
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

CREATE POLICY "Admin profile manage"
ON profiles FOR ALL
USING (public.is_current_user_admin())
WITH CHECK (public.is_current_user_admin());

DROP POLICY IF EXISTS "Cho phép đọc danh sách providers" ON earn_providers;

DROP POLICY IF EXISTS "Admin redemptions view" ON redemptions;
CREATE POLICY "Admin redemptions view"
ON redemptions FOR SELECT
USING (
  EXISTS (
    SELECT 1
    FROM profiles admin_profiles
    WHERE admin_profiles.id = auth.uid()
      AND admin_profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admin redemptions update" ON redemptions;
CREATE POLICY "Admin redemptions update"
ON redemptions FOR UPDATE
USING (
  EXISTS (
    SELECT 1
    FROM profiles admin_profiles
    WHERE admin_profiles.id = auth.uid()
      AND admin_profiles.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM profiles admin_profiles
    WHERE admin_profiles.id = auth.uid()
      AND admin_profiles.role = 'admin'
  )
);

-- After this script, run cam_engine.sql in the same database to install the latest atomic functions.
