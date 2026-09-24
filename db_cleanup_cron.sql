-- Cơ chế dọn dẹp lịch sử tự động (Dành cho Lịch sử kiếm Cam)
-- Dữ liệu "Lịch sử kiếm cam" (link_verifications & cam_transactions type 'earn') sẽ bị xóa nếu cũ hơn 7 ngày để tối ưu dung lượng Supabase.

-- 1. Bạn có thể chạy thủ công đoạn mã này định kỳ:
DELETE FROM link_verifications 
WHERE created_at < NOW() - INTERVAL '7 days';

DELETE FROM cam_transactions 
WHERE type = 'earn' AND created_at < NOW() - INTERVAL '7 days';


-- ==========================================
-- [NÂNG CAO] 2. Tự động hóa bằng PG_CRON (Chạy tự động mỗi ngày)
-- Nếu bạn muốn Supabase tự chạy mỗi ngày 1 lần, hãy chạy đoạn mã sau:
-- Lưu ý: Supabase Free có thể cần bạn bật extension pg_cron trước.

/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Chạy dọn dẹp link_verifications mỗi đêm lúc 2:00 AM
SELECT cron.schedule(
  'cleanup_old_links',
  '0 2 * * *',
  $$ DELETE FROM link_verifications WHERE created_at < NOW() - INTERVAL '7 days' $$
);

-- Chạy dọn dẹp cam_transactions (chỉ mục earn) mỗi đêm lúc 2:30 AM
SELECT cron.schedule(
  'cleanup_old_earn_tx',
  '30 2 * * *',
  $$ DELETE FROM cam_transactions WHERE type = 'earn' AND created_at < NOW() - INTERVAL '7 days' $$
);
*/
