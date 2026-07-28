-- ============================================================================
-- Net-worth history is throttled, and the chart series is bounded.
--
-- Before: one row per profile PER TICK (17,280/player/day, ~121k over the
-- retention window), and the Portfolio chart fetched all of it unbounded.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';

select plan(8);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'authenticated', 'authenticated', 'hist@example.test',
        '{"display_name": "Hist"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);

delete from public.net_worth_history;

-- Ten ticks in quick succession used to write ten rows per player.
do $$ begin for i in 1..10 loop perform game.market_tick(); end loop; end $$;

select is((select count(*)::int from net_worth_history
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 1,
  'ten ticks inside the throttle window write ONE snapshot, not ten');

-- Net worth itself must still refresh every tick — positions mark live, and a
-- stale figure would show a wrong P/L between snapshots.
update public.profiles set net_worth = 0, trading_net_worth = 0
 where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select game.market_tick();
select ok((select net_worth from profiles
            where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') > 0,
  'net worth still recomputes on every tick, throttle or not');

-- Once the window passes, a new snapshot lands.
update public.net_worth_history set tick_at = tick_at - interval '5 minutes';
select game.market_tick();
select is((select count(*)::int from net_worth_history
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 2,
  'a snapshot lands once the throttle window has elapsed');

-- ---------------------------------------------------------------------------
-- The bounded series.
-- ---------------------------------------------------------------------------
insert into public.net_worth_history (user_id, net_worth, tick_at)
select 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 10000 + g,
       now() - make_interval(secs => g * 30)
  from generate_series(1, 2000) g;

select ok((select count(*) from get_net_worth_series(168, 240)) <= 240,
  'the series never returns more points than the requested bucket count');
select ok((select count(*) from get_net_worth_series(168, 240)) > 1,
  '...but it does return a usable series');
select ok((select count(*) from get_net_worth_series(168, 20)) <= 20,
  'a smaller bucket count returns proportionally fewer points');

-- Absurd inputs are clamped rather than trusted.
select ok((select count(*) from get_net_worth_series(999999, 999999)) <= 1000,
  'an absurd bucket request is clamped');

-- Other players' history stays private even through the RPC.
insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'authenticated', 'authenticated', 'other@example.test',
        '{"display_name": "Other"}'::jsonb);
insert into public.net_worth_history (user_id, net_worth, tick_at)
values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 999999999, now());

select ok((select coalesce(max(net_worth), 0) from get_net_worth_series(168, 240))
          < 999999999,
  'the series is scoped to the caller — no reading anyone else''s net worth');

select * from finish();
rollback;
