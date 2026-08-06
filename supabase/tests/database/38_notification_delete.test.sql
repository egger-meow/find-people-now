-- =============================================================================
-- pgTAP Test — 通知 DELETE RLS（own_notifications_delete，v1.40）
--
-- 涵蓋：
-- 1. 使用者可以刪除自己的通知
-- 2. 使用者無法刪除別人的通知（RLS 靜默過濾，刪 0 筆，不是報錯）
--
-- 執行：`supabase test db`
-- 全檔包在 BEGIN;...ROLLBACK; 內，測試結束自動還原，不需手動清理資料。
-- =============================================================================

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(2);

-- -----------------------------------------------------------------------------
-- 0. Setup
-- -----------------------------------------------------------------------------

create temp table fixtures (
  owner_id  uuid,
  other_id  uuid,
  n_own     uuid,
  n_other   uuid
);
insert into fixtures default values;
-- 測試要 `set local role authenticated` 真的切換角色實測 RLS（比照
-- 05_propose_location.test.sql / 19_waiting_room_realtime_rls.test.sql 的
-- 手法）——用 postgres 超級使用者直接查詢會繞過 RLS，看不出 delete policy
-- 到底有沒有把別人的通知擋下來。該角色也要能讀這張 temp fixtures 表。
grant select on fixtures to authenticated;

do $setup$
declare
  v_owner   uuid := gen_random_uuid();
  v_other   uuid := gen_random_uuid();
  v_n_own   uuid;
  v_n_other uuid;
begin
  insert into auth.users (id, email) values
    (v_owner, 'nd_owner@nycu.edu.tw'), (v_other, 'nd_other@nycu.edu.tw');
  insert into app_user (id, email, school, display_name, avatar_url, degree_level, contact_ig)
  select u, u::text || '@nycu.edu.tw', 'NYCU', 'ND ' || u::text, 'https://avatar.nd', 'UNDERGRAD', 'nd_ig'
    from unnest(array[v_owner, v_other]) as u;

  insert into notification (user_id, event_type, payload)
  values (v_owner, 'MATCH_SUCCESS', '{}'::jsonb)
  returning id into v_n_own;

  insert into notification (user_id, event_type, payload)
  values (v_other, 'MATCH_SUCCESS', '{}'::jsonb)
  returning id into v_n_other;

  update fixtures set owner_id = v_owner, other_id = v_other, n_own = v_n_own, n_other = v_n_other;
end;
$setup$;

set local role authenticated;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select owner_id::text from fixtures), true);
end $$;

-- -----------------------------------------------------------------------------
-- 1. 可以刪除自己的通知
-- -----------------------------------------------------------------------------

delete from notification where id = (select n_own from fixtures);

select is(
  (select count(*)::int from notification where id = (select n_own from fixtures)),
  0,
  '使用者應能刪除自己的通知'
);

-- -----------------------------------------------------------------------------
-- 2. 無法刪除別人的通知——RLS 靜默過濾，刪 0 筆，該筆仍存在
--
-- 用 owner 身份下的 SELECT 驗證「該筆還在」沒有意義——own_notifications_select
-- 本來就不放行讀別人的通知，不管 delete 有沒有生效，owner 視角下的 count 永遠
-- 是 0。改用 `reset role` 回到 postgres 超級使用者（繞過 RLS）直接查真相。
-- -----------------------------------------------------------------------------

delete from notification where id = (select n_other from fixtures);

reset role;

select is(
  (select count(*)::int from notification where id = (select n_other from fixtures)),
  1,
  '使用者不應能刪除別人的通知，該筆應仍存在（用 postgres 超級使用者繞過 RLS 查真相）'
);

select * from finish();

rollback;
