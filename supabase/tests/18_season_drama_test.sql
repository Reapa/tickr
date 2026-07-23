-- ============================================================================
-- Season-end drama: claim_season_result returns final standing + rewards once.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
select plan(6);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1',
        'authenticated', 'authenticated', 'gwen@example.test',
        '{"display_name": "Gwen"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1", "role": "authenticated"}', true);

-- A closed season Gwen won.
insert into public.seasons (id, number, name, starts_at, ends_at, status, reward_cosmetic_code)
values ('b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2', 99, 'Season 99',
        now() - interval '15 days', now() - interval '1 day', 'closed', 'frame_season_1');
insert into public.season_scores
  (season_id, user_id, starting_net_worth, current_net_worth, pct_return, final_rank)
values ('b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2',
        'a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1', 10000, 11500, 0.15, 1);

create temp table cr (label text primary key, receipt jsonb);

insert into cr values ('r', public.claim_season_result());
select is(receipt ->> 'status', 'result', 'a fresh closed-season result is returned')
  from cr where label = 'r';
select is((receipt ->> 'rank')::int, 1, 'the final rank is reported') from cr where label = 'r';
select is((receipt ->> 'reward_cash')::int, 5000, 'the winner gets the podium cash figure')
  from cr where label = 'r';
select is((receipt ->> 'top10')::boolean, true, 'first place is inside the top 10%')
  from cr where label = 'r';
select is(receipt ->> 'reward_cosmetic', 'frame_season_1',
  'the season cosmetic is reported for a top finisher') from cr where label = 'r';

-- Claiming again returns nothing (already acknowledged).
insert into cr values ('again', public.claim_season_result());
select is(receipt ->> 'status', 'none', 'a result is only revealed once')
  from cr where label = 'again';

select * from finish();
rollback;
