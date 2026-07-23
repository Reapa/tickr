-- ============================================================================
-- Reward crates: grant, open (cosmetic / XP / fallback), welcome, streak drop.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
select plan(9);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        'authenticated', 'authenticated', 'dave@example.test',
        '{"display_name": "Dave"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "role": "authenticated"}', true);

create temp table cr (label text primary key, receipt jsonb);

-- New players get a welcome crate (from the profiles insert trigger).
select is((select count(*)::int from public.user_crates
            where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
              and source = 'welcome' and not opened),
  1, 'a new player receives one welcome crate');

-- Grant + open.
insert into cr values ('open', public.open_crate(
  game.grant_crate('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'common', 'test')));
select is(receipt ->> 'status', 'opened', 'a crate opens') from cr where label = 'open';
select ok(receipt ->> 'kind' in ('xp', 'cosmetic'), 'an opened crate yields xp or a cosmetic')
  from cr where label = 'open';

-- Re-opening the same crate is rejected.
insert into cr values ('grant2', to_jsonb(
  game.grant_crate('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'common', 'test')::text));
select public.open_crate((select (receipt #>> '{}')::uuid from cr where label = 'grant2'));
insert into cr values ('reopen', public.open_crate(
  (select (receipt #>> '{}')::uuid from cr where label = 'grant2')));
select is(receipt ->> 'reason', 'already opened', 'a crate cannot be opened twice')
  from cr where label = 'reopen';

-- The cosmetic path actually grants a cosmetic (legendary crates are 80%
-- cosmetic; over 12 opens a grant is a near-certainty).
do $$ declare i int; begin
  for i in 1..12 loop
    perform public.open_crate(
      game.grant_crate('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'legendary', 'test'));
  end loop;
end $$;
select ok((select count(*) from public.user_cosmetics
            where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
              and acquired_via = 'grant') >= 1,
  'opening crates can grant cosmetics');

-- Owning every eligible cosmetic falls back to XP.
insert into public.user_cosmetics (user_id, cosmetic_id, acquired_via)
select 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', c.id, 'grant'
  from public.cosmetics c
 where not c.is_season_reward
   and not exists (select 1 from public.user_cosmetics uc
                    where uc.user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
                      and uc.cosmetic_id = c.id)
on conflict do nothing;
insert into cr values ('fallback', public.open_crate(
  game.grant_crate('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'legendary', 'test')));
select is(receipt ->> 'kind', 'xp', 'owning every cosmetic falls back to XP')
  from cr where label = 'fallback';
select ok((receipt ->> 'xp')::int > 0, 'the XP fallback awards XP')
  from cr where label = 'fallback';

-- A day-7 streak milestone drops a crate.
update public.profiles
   set streak_days = 6, last_claim_date = (now() at time zone 'utc')::date - 1
 where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
insert into cr values ('claim', public.claim_daily_reward());
select is((receipt ->> 'milestone')::boolean, true, 'day 7 is a streak milestone')
  from cr where label = 'claim';
select ok((select count(*) from public.user_crates
            where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
              and source = 'streak') >= 1,
  'a streak milestone drops a crate');

select * from finish();
rollback;
