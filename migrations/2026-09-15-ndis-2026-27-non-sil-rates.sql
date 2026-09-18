-- NDIS 2026-27 price refresh for non-SIL budget lines.
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- WHY: budget lines snapshot RATE_CARDS into participants.budget_lines[].rates
-- when the line is created, and _buildInvLines invoices from that snapshot —
-- never from RATE_CARDS. So the 2026-27 RATE_CARDS update in index.html does
-- nothing for existing lines until their stored rates are rewritten. SIL got
-- the same treatment in-app (migrateSilRates2026); this is the SQL equivalent
-- for the core, community, core_combined and employment cards.
--
-- SOURCE: NDIS Pricing Schedule 2026-27 v1.2, national non-remote limits.
--   01_011_0107_1_1 weekday $73.58      04_104_0125_6_1 weekday $73.58
--   01_015_0107_1_1 evening $81.07      04_105_0125_6_1 saturday $103.54
--   01_002_0107_1_1 night $82.57        04_106_0125_6_1 sunday $133.50
--   01_013_0107_1_1 saturday $103.54    04_102_0125_6_1 public holiday $163.46
--   01_014_0107_1_1 sunday $133.50      04_799_0125_6_1 provider travel non-labour
--   01_012_0107_1_1 public hol $163.46
--   01_010_0107_1_1 sleepover $311.79 (unit "Each")
--   10_016_0102_5_3 employment $83.87
--
-- GUARD (same rule as migrateSilRates2026): a rate row is rewritten ONLY when
-- its card, group, day_type, code AND rate all still equal the old 2025-26
-- default. Anything an operator edited by hand is left exactly as it is.
--
-- WHAT CHANGES, per line, inside `rates` only:
--   core           six hourly rows bumped; a sleepover row appended if the
--                  line has none
--   community      rates bumped, and three wrong codes fixed:
--                    saturday 04_103 (that's Weekday Evening) -> 04_105
--                    sunday   04_105 (that's Saturday)        -> 04_106
--                    travel   04_210 (quote-based activity)   -> 04_799
--                  travel stays $0.99/km — only its code changes
--   core_combined  both groups' weekday/sat/sun/public-holiday rows bumped;
--                  each group keeps its own code (0107 vs 0125)
--   employment     10_016_0102_5_3 $80.06 -> $83.87; travel unchanged
--
-- NOT TOUCHED:
--   sil            already 2026-27 (migrateSilRates2026)
--   custom         has no defaults, so there is no old value to guard against
--   travel_km      $0.99 kept on every card (NDIA's stated per-km contribution
--                  in the 2025-26 Pricing Arrangements; schedule item is $1.00)
--   id, name, active, rate_card, travel, funding, bill_to — every field of a
--   budget line except `rates`
--   archived participants ARE included (archived_at is not filtered)
--
-- IDEMPOTENT: once a row is bumped it no longer matches its old value, and the
-- sleepover row is only appended when absent, so a second run changes nothing.
--
-- PREVIEW FIRST: run everything from `with` down to the end of the `computed`
-- CTE followed by the preview select at the bottom of this file (commented
-- out), instead of the update.

begin;

with bumps(rate_card, grp, day_type, old_code, old_rate, new_code, new_rate) as (
  values
    -- core (0107)
    ('core',          null::text,   'weekday',        '01_011_0107_1_1', 70.23::numeric,  '01_011_0107_1_1', 73.58::numeric),
    ('core',          null,         'evening',        '01_015_0107_1_1', 77.38,           '01_015_0107_1_1', 81.07),
    ('core',          null,         'night',          '01_002_0107_1_1', 78.81,           '01_002_0107_1_1', 82.57),
    ('core',          null,         'saturday',       '01_013_0107_1_1', 98.83,           '01_013_0107_1_1', 103.54),
    ('core',          null,         'sunday',         '01_014_0107_1_1', 127.43,          '01_014_0107_1_1', 133.50),
    ('core',          null,         'public_holiday', '01_012_0107_1_1', 156.03,          '01_012_0107_1_1', 163.46),
    -- community (0125) — codes corrected where they were wrong
    ('community',     null,         'weekday',        '04_104_0125_6_1', 70.23,           '04_104_0125_6_1', 73.58),
    ('community',     null,         'saturday',       '04_103_0125_6_1', 98.83,           '04_105_0125_6_1', 103.54),
    ('community',     null,         'sunday',         '04_105_0125_6_1', 127.43,          '04_106_0125_6_1', 133.50),
    ('community',     null,         'public_holiday', '04_102_0125_6_1', 156.03,          '04_102_0125_6_1', 163.46),
    ('community',     null,         'travel_km',      '04_210_0125_6_1', 0.99,            '04_799_0125_6_1', 0.99),
    -- core_combined — 0107 daily life group
    ('core_combined', 'daily_life', 'weekday',        '01_011_0107_1_1', 70.23,           '01_011_0107_1_1', 73.58),
    ('core_combined', 'daily_life', 'saturday',       '01_013_0107_1_1', 98.83,           '01_013_0107_1_1', 103.54),
    ('core_combined', 'daily_life', 'sunday',         '01_014_0107_1_1', 127.43,          '01_014_0107_1_1', 133.50),
    ('core_combined', 'daily_life', 'public_holiday', '01_012_0107_1_1', 156.03,          '01_012_0107_1_1', 163.46),
    -- core_combined — 0125 community group
    ('core_combined', 'community',  'weekday',        '04_104_0125_6_1', 70.23,           '04_104_0125_6_1', 73.58),
    ('core_combined', 'community',  'saturday',       '04_105_0125_6_1', 98.83,           '04_105_0125_6_1', 103.54),
    ('core_combined', 'community',  'sunday',         '04_106_0125_6_1', 127.43,          '04_106_0125_6_1', 133.50),
    ('core_combined', 'community',  'public_holiday', '04_102_0125_6_1', 156.03,          '04_102_0125_6_1', 163.46),
    -- employment (0102)
    ('employment',    null,         'any_day',        '10_016_0102_5_3', 80.06,           '10_016_0102_5_3', 83.87)
),
computed as (
  select p.id, p.name, p.budget_lines as old_lines,
    (
      select jsonb_agg(
        case
          when coalesce(l.bl->>'rate_card', '') not in ('core', 'community', 'core_combined', 'employment')
            or coalesce(jsonb_typeof(l.bl->'rates'), '') <> 'array'
            then l.bl
          else jsonb_set(l.bl, '{rates}',
            (
              select coalesce(jsonb_agg(
                coalesce(
                  (select e.r || jsonb_build_object('code', b.new_code, 'rate', b.new_rate)
                     from bumps b
                    where b.rate_card = l.bl->>'rate_card'
                      and b.grp is not distinct from e.r->>'group'
                      and b.day_type = e.r->>'day_type'
                      and b.old_code = e.r->>'code'
                      and (e.r->>'rate') ~ '^\s*[0-9]+(\.[0-9]+)?\s*$'
                      and abs((e.r->>'rate')::numeric - b.old_rate) < 0.005),
                  e.r
                ) order by e.ord), '[]'::jsonb)
              from jsonb_array_elements(l.bl->'rates') with ordinality e(r, ord)
            )
            ||
            case
              when l.bl->>'rate_card' = 'core'
               and not exists (select 1 from jsonb_array_elements(l.bl->'rates') x(r)
                                where x.r->>'day_type' = 'sleepover')
                then jsonb_build_array(jsonb_build_object(
                       'day_type', 'sleepover',
                       'code',     '01_010_0107_1_1',
                       'desc',     'Assistance with Self-Care – Night-Time Sleepover',
                       'rate',     311.79))
              else '[]'::jsonb
            end
          )
        end
        order by l.ord)
      from jsonb_array_elements(p.budget_lines) with ordinality l(bl, ord)
    ) as new_lines
  from participants p
  where jsonb_typeof(p.budget_lines) = 'array'
    and jsonb_array_length(p.budget_lines) > 0
)
update participants p
   set budget_lines = c.new_lines
  from computed c
 where p.id = c.id
   and c.new_lines is distinct from c.old_lines
returning p.id, p.name;

commit;

-- PREVIEW (read-only) — swap in for the update above to see each changed rate
-- row before running:
--
-- select c.name, ol.bl->>'id' as line_id, ol.bl->>'rate_card' as card,
--        o.r->>'group' as grp, o.r->>'day_type' as day_type,
--        o.r->>'code' as old_code, o.r->>'rate' as old_rate,
--        n.r->>'code' as new_code, n.r->>'rate' as new_rate
--   from computed c
--   join lateral jsonb_array_elements(c.old_lines) with ordinality ol(bl, ord) on true
--   join lateral jsonb_array_elements(c.new_lines) with ordinality nl(bl, ord) on nl.ord = ol.ord
--   join lateral jsonb_array_elements(nl.bl->'rates') with ordinality n(r, ord) on true
--   left join lateral jsonb_array_elements(ol.bl->'rates') with ordinality o(r, ord) on o.ord = n.ord
--  where o.r is distinct from n.r
--  order by c.name, line_id, n.ord;
