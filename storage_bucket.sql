-- Tạo storage bucket để chứa mã QR rút tiền
insert into storage.buckets (id, name, public)
values ('qrcodes', 'qrcodes', true);

-- Thiết lập chính sách bảo mật cho bucket
create policy "Public Access"
on storage.objects for select
using ( bucket_id = 'qrcodes' );

create policy "Auth Upload"
on storage.objects for insert
with check ( bucket_id = 'qrcodes' AND auth.role() = 'authenticated' );

create policy "Auth Delete"
on storage.objects for delete
using ( bucket_id = 'qrcodes' AND auth.role() = 'authenticated' );
