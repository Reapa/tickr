-- ============================================================================
-- Prediction micro-bets: make a call, resolve at the close price, pay XP to the
-- correct callers only.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';
update public.game_config set value = '0' where key = 'prediction_post_probability';

select plan(8);

update public.assets set current_price = 100, fair_value = 100 where symbol = 'GOGL';

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'ffffffff-ffff-4fff-8fff-ffffffffffff',
        'authenticated', 'authenticated', 'frank@example.test',
        '{"display_name": "Frank"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "ffffffff-ffff-4fff-8fff-ffffffffffff", "role": "authenticated"}', true);

create temp table pr (label text primary key, id uuid);
create temp table cr (label text primary key, receipt jsonb);

-- A prediction the player will call correctly (price rises).
with ins as (
  insert into public.predictions (asset_id, question, opens_at, closes_at, open_price, reward_xp)
  values ((select id from public.assets where symbol = 'GOGL'),
          'Will GOGL be higher in 3 min?',
          now() - interval '1 hour', now() + interval '1 hour', 100, 50)
  returning id)
insert into pr select 'p1', id from ins;

insert into cr select 'call', public.make_prediction((select id from pr where label = 'p1'), 'up');
select is(receipt ->> 'status', 'placed', 'a call is placed') from cr where label = 'call';

insert into cr select 'dup', public.make_prediction((select id from pr where label = 'p1'), 'down');
select is(receipt ->> 'reason', 'already answered', 'a prediction can be answered once')
  from cr where label = 'dup';

-- Resolve it: GOGL rose, so 'up' wins.
update public.assets set current_price = 200 where symbol = 'GOGL';
update public.predictions set closes_at = now() - interval '1 second'
 where id = (select id from pr where label = 'p1');
select game.tick_predictions();

select is(result, 'up', 'the prediction resolves to the true direction')
  from public.predictions where id = (select id from pr where label = 'p1');
select is(correct, true, 'the correct caller is marked correct')
  from public.user_predictions
 where prediction_id = (select id from pr where label = 'p1');
select is(awarded_xp, 50, 'the correct caller is paid the reward XP')
  from public.user_predictions
 where prediction_id = (select id from pr where label = 'p1');
select is((select xp from public.profiles where id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
  50, 'the reward XP lands on the profile');

-- A losing call (price rises, player said down).
with ins as (
  insert into public.predictions (asset_id, question, opens_at, closes_at, open_price, reward_xp)
  values ((select id from public.assets where symbol = 'GOGL'),
          'Will GOGL be higher in 3 min?',
          now() - interval '1 hour', now() + interval '1 hour', 200, 60)
  returning id)
insert into pr select 'p2', id from ins;
select public.make_prediction((select id from pr where label = 'p2'), 'down');
update public.assets set current_price = 300 where symbol = 'GOGL';
update public.predictions set closes_at = now() - interval '1 second'
 where id = (select id from pr where label = 'p2');
select game.tick_predictions();

select is(correct, false, 'a wrong caller is marked incorrect')
  from public.user_predictions
 where prediction_id = (select id from pr where label = 'p2');
select is(awarded_xp, 0, 'a wrong caller earns nothing')
  from public.user_predictions
 where prediction_id = (select id from pr where label = 'p2');

select * from finish();
rollback;
