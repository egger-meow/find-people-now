import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 反饋：大頭貼要能真的上傳，不是只能重骰隨機圖（see `avatars` storage bucket,
/// `supabase/migrations/20260729140000_avatars_storage_bucket.sql`）。
///
/// 回傳 `null` 代表使用者取消了選圖（不是錯誤）——呼叫端不需要特別處理錯誤
/// 分支，維持原本選圖前的頭像即可。上傳失敗（網路、bucket 權限等）則讓
/// `uploadBinary`/`getPublicUrl` 的例外往上拋，交給呼叫端既有的 try/catch。
Future<String?> pickAndUploadAvatar(SupabaseClient client, String userId) async {
  final picker = ImagePicker();
  final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024, imageQuality: 85);
  if (picked == null) return null;

  final bytes = await picked.readAsBytes();
  final ext = picked.name.contains('.') ? picked.name.split('.').last.toLowerCase() : 'jpg';
  final path = '$userId/${DateTime.now().millisecondsSinceEpoch}.$ext';

  await client.storage.from('avatars').uploadBinary(
        path,
        bytes,
        fileOptions: FileOptions(contentType: picked.mimeType, upsert: true),
      );

  return client.storage.from('avatars').getPublicUrl(path);
}
