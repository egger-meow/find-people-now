-- =============================================================================
-- 官方預設活動：唱K、練舞 與 DANCE_GENRE 撮合相容性判定
-- =============================================================================

-- 1. 更新 fn_sport_level_match：支援 DANCE_GENRE
create or replace function fn_sport_level_match(
  p_system level_system,
  p_a text,
  p_b text
)
returns boolean
language plpgsql
immutable
as $$
declare
  v_a_num numeric;
  v_b_num numeric;
begin
  -- null = wildcard（不限 / 不確定，與任何等級皆相容）
  if p_a is null or p_b is null then
    return true;
  end if;

  if p_system = 'NONE' or p_system is null then
    return true;
  end if;

  -- 練舞曲風：相同曲風相容（null 為不限/wildcard）
  if p_system = 'DANCE_GENRE' then
    return p_a = p_b;
  end if;

  -- 籃球強度：相鄰等級相容 (|a - b| <= 1)
  if p_system = 'BASKETBALL_INTENSITY' then
    v_a_num := case p_a
      when 'EASY' then 1
      when 'REGULAR' then 2
      when 'HIGH' then 3
      when 'COMPETITIVE' then 4
      else null
    end;
    v_b_num := case p_b
      when 'EASY' then 1
      when 'REGULAR' then 2
      when 'HIGH' then 3
      when 'COMPETITIVE' then 4
      else null
    end;
    if v_a_num is null or v_b_num is null then
      return true;
    end if;
    return abs(v_a_num - v_b_num) <= 1;
  end if;

  -- 羽球實力級數：相鄰級數區間相容 (|a - b| <= 1)
  if p_system = 'BADMINTON_LEVEL' then
    v_a_num := case p_a
      when 'LEVEL_1_5' then 1
      when 'LEVEL_6_7' then 2
      when 'LEVEL_8_10' then 3
      when 'LEVEL_11_PLUS' then 4
      else null
    end;
    v_b_num := case p_b
      when 'LEVEL_1_5' then 1
      when 'LEVEL_6_7' then 2
      when 'LEVEL_8_10' then 3
      when 'LEVEL_11_PLUS' then 4
      else null
    end;
    if v_a_num is null or v_b_num is null then
      return true;
    end if;
    return abs(v_a_num - v_b_num) <= 1;
  end if;

  -- 網球 NTRP：差值 <= 0.5 相容
  if p_system = 'TENNIS_NTRP' then
    v_a_num := case p_a
      when 'NTRP_2_0' then 2.0
      when 'NTRP_2_5' then 2.5
      when 'NTRP_3_0' then 3.0
      when 'NTRP_3_5' then 3.5
      when 'NTRP_4_0' then 4.0
      when 'NTRP_4_5' then 4.5
      when 'NTRP_5_0_PLUS' then 5.0
      when '2.0' then 2.0
      when '2.5' then 2.5
      when '3.0' then 3.0
      when '3.5' then 3.5
      when '4.0' then 4.0
      when '4.5' then 4.5
      when '5.0' then 5.0
      else null
    end;
    v_b_num := case p_b
      when 'NTRP_2_0' then 2.0
      when 'NTRP_2_5' then 2.5
      when 'NTRP_3_0' then 3.0
      when 'NTRP_3_5' then 3.5
      when 'NTRP_4_0' then 4.0
      when 'NTRP_4_5' then 4.5
      when 'NTRP_5_0_PLUS' then 5.0
      when '2.0' then 2.0
      when '2.5' then 2.5
      when '3.0' then 3.0
      when '3.5' then 3.5
      when '4.0' then 4.0
      when '4.5' then 4.5
      when '5.0' then 5.0
      else null
    end;
    if v_a_num is null or v_b_num is null then
      return true;
    end if;
    return abs(v_a_num - v_b_num) <= 0.5;
  end if;

  -- 桌球實力：相鄰組別相容 (|a - b| <= 1)
  if p_system = 'TABLE_TENNIS_SKILL' then
    v_a_num := case p_a
      when 'CASUAL_BEGINNER' then 1
      when 'BASIC_SKILLS' then 2
      when 'REGULAR_PLAYER' then 3
      when 'VARSITY_TOURNAMENT' then 4
      else null
    end;
    v_b_num := case p_b
      when 'CASUAL_BEGINNER' then 1
      when 'BASIC_SKILLS' then 2
      when 'REGULAR_PLAYER' then 3
      when 'VARSITY_TOURNAMENT' then 4
      else null
    end;
    if v_a_num is null or v_b_num is null then
      return true;
    end if;
    return abs(v_a_num - v_b_num) <= 1;
  end if;

  return true;
end;
$$;

-- 2. 新增官方活動類型：唱K、練舞
insert into activity_type (
  name, status, default_duration_minutes,
  default_min_participants, default_max_participants, group_size_step,
  level_system, sort_order, aliases, description
) values
  ('唱K', 'APPROVED', 180, 2, 30, null, 'NONE', 10,
   array['唱歌', 'KTV', '卡拉OK', 'Karaoke', '唱k'],
   '揪人去唱KTV！包廂歡唱、唱歌聚會。地點由參與者自行協調（例如巨城錢櫃、好樂迪等）。'),
  ('練舞', 'APPROVED', 120, 2, 30, null, 'DANCE_GENRE', 11,
   array['跳舞', '街舞', '熱舞', 'Dance', 'Dancing'],
   '揪人一起練舞、雕舞、交流！可選擇專屬曲風（Hip-Hop、Jazz、Girl Style、Popping、Locking、K-Pop、其他或不限）。地點常見於校內鏡面走廊、舞蹈教室或活動中心。')
on conflict (name) do update
  set status = excluded.status,
      default_duration_minutes = excluded.default_duration_minutes,
      default_min_participants = excluded.default_min_participants,
      default_max_participants = excluded.default_max_participants,
      group_size_step = excluded.group_size_step,
      level_system = excluded.level_system,
      sort_order = excluded.sort_order,
      aliases = excluded.aliases,
      description = excluded.description;
