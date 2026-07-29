import '../generated/supadart_header.dart' show SCHOOL;

/// 反饋：個人資料卡、候選人資訊卡等畫面原本直接印列舉原始值（`NYCU`/`NTHU`），
/// 使用者反應看起來像是系統沒有記錄大學——其實從報名 email 網域就已經正確
/// 判斷出來了（見 `complete_profile` RPC 的 email regex，
/// `supabase/migrations/20260724120200_rpc_profile_and_auth.sql:69-74`），只是
/// 顯示字串太像內部代碼，不像「這是你的學校」，這裡統一改印中文全名。
String schoolLabel(SCHOOL school) => switch (school) {
      SCHOOL.NYCU => '國立陽明交通大學',
      SCHOOL.NTHU => '國立清華大學',
    };

/// 註冊畫面（`complete_profile_screen.dart`）此時 `app_user` 列還不存在，拿不到
/// 已存好的 `school`，但科系下拉選單需要先知道要顯示哪一校的清單——直接在
/// client 端比照後端同一條 regex（大小寫不敏感）從登入 email 反推，純粹是
/// UI 用途（決定顯示哪份清單），不是權威判斷：真正的 `school` 欄位仍然只由
/// `complete_profile` RPC 依 `auth.users.email` 寫入，這裡算錯也不影響資料
/// 正確性，最多只是科系選單顯示錯的清單。
SCHOOL? schoolFromEmail(String? email) {
  if (email == null) return null;
  final lower = email.toLowerCase();
  if (lower.endsWith('@nycu.edu.tw')) return SCHOOL.NYCU;
  if (lower.endsWith('@nthu.edu.tw')) return SCHOOL.NTHU;
  return null;
}
