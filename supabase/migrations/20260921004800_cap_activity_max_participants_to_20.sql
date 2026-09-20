-- =============================================================================
-- 將各活動類型的人數上限由 30 調整為 20 人（v1.44）
-- 避免人數選項過多過長，統一支援最多 20 人成團。
-- =============================================================================

update activity_type
   set default_max_participants = 20
 where default_max_participants > 20
    or default_max_participants is null;
