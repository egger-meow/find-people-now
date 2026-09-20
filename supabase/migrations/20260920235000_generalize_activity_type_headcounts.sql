-- =============================================================================
-- 泛化所有活動類型的人數範圍（v1.43）
-- 解決「跑步」等活動被鎖死在 3-4 人狹窄區間的問題，全面將各活動的
-- default_min_participants 設為 2，default_max_participants 擴展至 30 人，
-- 並移除 group_size_step 限制（改為任意整數人數皆可成立），讓使用者能自由
-- 選擇 2 到 30 人的廣闊規模。
-- =============================================================================

update activity_type
   set default_min_participants = 2,
       default_max_participants = 30,
       group_size_step = null
 where status = 'APPROVED';
