-- Hotfix lỗi: infinite recursion detected in policy for relation "profiles"
-- Chạy trực tiếp trong Supabase SQL Editor trên production.

BEGIN;

DROP POLICY IF EXISTS "Self profile view" ON public.profiles;
DROP POLICY IF EXISTS "Admin profile view" ON public.profiles;
DROP POLICY IF EXISTS "Self update profile" ON public.profiles;
DROP POLICY IF EXISTS "Admin profile manage" ON public.profiles;

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
ON public.profiles FOR SELECT
USING (auth.uid() = id);

CREATE POLICY "Admin profile view"
ON public.profiles FOR SELECT
USING (public.is_current_user_admin());

CREATE POLICY "Self update profile"
ON public.profiles FOR UPDATE
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
ON public.profiles FOR ALL
USING (public.is_current_user_admin())
WITH CHECK (public.is_current_user_admin());

COMMIT;
