-- =============================================================================
-- activity_member.source_request_id is a FK to match_request(id) with no
-- supporting index. It's joined directly in the skill_level and study_target
-- history RPCs (20260803160100_skill_level_rpc.sql,
-- 20260803160300_study_target_rpc.sql: `join match_request mr on mr.id =
-- am.source_request_id`), so this is an exercised query path, not
-- speculative indexing.
-- =============================================================================

create index if not exists idx_activity_member_source_request_id
  on activity_member (source_request_id);
