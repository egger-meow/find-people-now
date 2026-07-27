-- =============================================================================
-- 帳號刪除（一）：schema — app_user.deleted_at + CHECK 約束放寬（v1.14）
--
-- 帳號刪除採「app_user row 保留、去識別化，id 不變」策略，不做真正的 row
-- DELETE：app_user.id 對 auth.users(id) 掛的是 on delete cascade（見 init
-- migration），若真的刪掉 app_user，會撞上 13 張子表（match_request.owner_id
-- 等）沒有 on delete cascade 的 FK；若改成先清空子表，又會讓其他使用者依賴
-- 的 reliability / 得票數 / 集合點等共用資料連帶失真。保留 row、只清空識別
-- 欄位，id 不變，是唯一不需要動任何子表 FK 的方案。
--
-- deleted_at 是這個策略需要的唯一新欄位：
--   1. 區分「這是一個被去識別化的殼」還是「剛好顯示名稱普通的真帳號」
--   2. delete_account() RPC 冪等判斷的依據（比照 GoTrue 官方 admin.deleteUser
--      soft-delete 對已刪除帳號重複呼叫直接 no-op 的行為）
--   3. 所有身分驗證類 RPC 的 ACCOUNT_DELETED 檢查依據（見下一份 migration）
--
-- 不新增 deleted_reason：目前只有使用者自行發起這一條刪除路徑，沒有 admin/
-- GDPR 代刪這類假設性未來路徑需要區分，不為不存在的需求預先開欄位。
-- =============================================================================

alter table app_user add column deleted_at timestamptz;

-- -----------------------------------------------------------------------------
-- email 相關兩條 CHECK 約束都要放寬：deleted_at 帳號的 email 改存
-- 'deleted+<uuid>' 佔位值（不再偽造一個符合雙校網域格式的假信箱），格式本身
-- 就不符合下面兩條約束原本要求的網域比對，故兩者都補上
-- 「deleted_at is not null or ...」短路條件，讓已刪除帳號跳過網域格式檢查。
-- CHECK 約束不能原地修改，只能 drop 掉舊的再補一條新的。
-- -----------------------------------------------------------------------------

alter table app_user drop constraint app_user_email_check;
alter table app_user add constraint app_user_email_check
  check (deleted_at is not null or email ~* '^[^@]+@(nycu|nthu)\.edu\.tw$');

alter table app_user drop constraint school_matches_email;
alter table app_user add constraint school_matches_email
  check (
    deleted_at is not null or
    (school = 'NYCU' and email ~* '@nycu\.edu\.tw$') or
    (school = 'NTHU' and email ~* '@nthu\.edu\.tw$')
  );
