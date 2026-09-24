-- migration_cascade.sql
-- Them ON DELETE CASCADE cho cac bang phu thuoc profiles, de delete user khong fail
-- Chay trong Supabase SQL Editor

-- cam_transactions: user_id -> profiles(id)
ALTER TABLE cam_transactions DROP CONSTRAINT IF EXISTS cam_transactions_user_id_fkey;
ALTER TABLE cam_transactions
  ADD CONSTRAINT cam_transactions_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;

-- transfers: sender_id, receiver_id -> profiles(id)
ALTER TABLE transfers DROP CONSTRAINT IF EXISTS transfers_sender_id_fkey;
ALTER TABLE transfers
  ADD CONSTRAINT transfers_sender_id_fkey
  FOREIGN KEY (sender_id) REFERENCES profiles(id) ON DELETE CASCADE;

ALTER TABLE transfers DROP CONSTRAINT IF EXISTS transfers_receiver_id_fkey;
ALTER TABLE transfers
  ADD CONSTRAINT transfers_receiver_id_fkey
  FOREIGN KEY (receiver_id) REFERENCES profiles(id) ON DELETE CASCADE;

-- redemptions: user_id -> profiles(id)
ALTER TABLE redemptions DROP CONSTRAINT IF EXISTS redemptions_user_id_fkey;
ALTER TABLE redemptions
  ADD CONSTRAINT redemptions_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;

-- referral_earnings: referrer_id, referee_id -> profiles(id)
ALTER TABLE referral_earnings DROP CONSTRAINT IF EXISTS referral_earnings_referrer_id_fkey;
ALTER TABLE referral_earnings
  ADD CONSTRAINT referral_earnings_referrer_id_fkey
  FOREIGN KEY (referrer_id) REFERENCES profiles(id) ON DELETE CASCADE;

ALTER TABLE referral_earnings DROP CONSTRAINT IF EXISTS referral_earnings_referee_id_fkey;
ALTER TABLE referral_earnings
  ADD CONSTRAINT referral_earnings_referee_id_fkey
  FOREIGN KEY (referee_id) REFERENCES profiles(id) ON DELETE CASCADE;

-- notifications: user_id -> profiles(id)
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_user_id_fkey;
ALTER TABLE notifications
  ADD CONSTRAINT notifications_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;

-- security_flags: user_id -> profiles(id)
ALTER TABLE security_flags DROP CONSTRAINT IF EXISTS security_flags_user_id_fkey;
ALTER TABLE security_flags
  ADD CONSTRAINT security_flags_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;

-- earn_tasks: user_id -> profiles(id)
ALTER TABLE earn_tasks DROP CONSTRAINT IF EXISTS earn_tasks_user_id_fkey;
ALTER TABLE earn_tasks
  ADD CONSTRAINT earn_tasks_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;

-- admin_audit_log: admin_id -> profiles(id)
ALTER TABLE admin_audit_log DROP CONSTRAINT IF EXISTS admin_audit_log_admin_id_fkey;
ALTER TABLE admin_audit_log
  ADD CONSTRAINT admin_audit_log_admin_id_fkey
  FOREIGN KEY (admin_id) REFERENCES profiles(id) ON DELETE SET NULL;

-- profiles: referred_by -> profiles(id) (set null khi referrer bi xoa)
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_referred_by_fkey;
ALTER TABLE profiles
  ADD CONSTRAINT profiles_referred_by_fkey
  FOREIGN KEY (referred_by) REFERENCES profiles(id) ON DELETE SET NULL;

-- link_verifications: used_by, created_by -> profiles(id)
ALTER TABLE link_verifications DROP CONSTRAINT IF EXISTS link_verifications_used_by_fkey;
ALTER TABLE link_verifications
  ADD CONSTRAINT link_verifications_used_by_fkey
  FOREIGN KEY (used_by) REFERENCES profiles(id) ON DELETE SET NULL;

ALTER TABLE link_verifications DROP CONSTRAINT IF EXISTS link_verifications_created_by_fkey;
ALTER TABLE link_verifications
  ADD CONSTRAINT link_verifications_created_by_fkey
  FOREIGN KEY (created_by) REFERENCES profiles(id) ON DELETE SET NULL;

-- bonus_claims (neu co): user_id -> profiles(id)
ALTER TABLE bonus_claims DROP CONSTRAINT IF EXISTS bonus_claims_user_id_fkey;
ALTER TABLE bonus_claims
  ADD CONSTRAINT bonus_claims_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;
