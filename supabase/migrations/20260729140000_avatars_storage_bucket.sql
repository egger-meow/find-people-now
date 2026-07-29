-- =============================================================================
-- 大頭貼上傳：新增 `avatars` Storage bucket + storage.objects RLS
-- =============================================================================
-- 反饋：「為甚麼是換一個頭像然後點一下隨便跳一個 要設定 可以上傳阿」——先前
-- 大頭貼只能靠 dicebear 隨機重骰（見 complete_profile_screen.dart /
-- edit_profile_screen.dart 的 `_rerollAvatar`），沒有真正上傳圖片的路徑。
--
-- 路徑慣例：`{auth.uid()}/{filename}`——RLS 用路徑的第一段（
-- `storage.foldername(name)`）比對 `auth.uid()`，讓使用者只能寫入/覆蓋/刪除
-- 自己資料夾底下的物件。Bucket 設為 public：大頭貼本來就是要給別人看的
-- （UI_PLAN §8.1 個人資料卡、對方安全資訊卡都會顯示），不像
-- match_history_avoidance/pending_confirmation 那種刻意不給讀的表，這裡沒有
-- 對稱不歸因的顧慮。
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 5242880, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

create policy avatars_public_select on storage.objects
  for select using (bucket_id = 'avatars');

create policy avatars_own_folder_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy avatars_own_folder_update on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy avatars_own_folder_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
