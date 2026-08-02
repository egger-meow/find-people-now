-- =============================================================================
-- app_user.default_campus（v1.32）
-- 派生自使用者需求：註冊時選一次「平常在哪個校區」，之後建立揪團直接帶入，
-- 省去每次都要重選。刻意比照 v1.11 對 location.campus 的決定——純文字、不開
-- table、不開 FK，campus 清單本來就是 location 資料的衍生集合
-- （`select distinct campus from location`），這裡存的只是「使用者上次/預設
-- 選哪個」，不是一份需要正規化管理的 master data。
-- =============================================================================

alter table app_user
  add column default_campus text;

-- 20260724125200_restrict_app_user_notification_column_grants.sql 收斂過
-- app_user 的 column-level UPDATE 授權成白名單，這裡新增一欄要能讓使用者自己
-- PATCH（供 create_request_screen 送出時「回寫成新預設值」），需要額外放行，
-- 不能只靠 alter table 新增欄位就自動繼承舊的整欄授權（那個授權早就被收回了）。
grant update (default_campus) on app_user to authenticated;
