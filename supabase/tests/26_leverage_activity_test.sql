-- ============================================================================
-- Leveraged trades appear in both activity feeds, with their realized P/L.
-- Regression: leveraged closes were stored outside `orders`, so the Portfolio
-- feed (which read `orders`) never showed them and the Compete feed showed
-- entries with a hardcoded null P/L.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';

select plan(10);

update public.assets set current_price = 182.50, fair_value = 182.50, flow = 0
 where symbol = 'GOGL';

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'authenticated', 'authenticated', 'ava@example.test',
        '{"display_name": "Ava"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);

insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'mission_reward', 200000,
        'mission', 'test-grant');
select purchase_asset_class_unlock('margin');

-- A spot round trip and a leveraged round trip.
select place_market_order((select id from assets where symbol = 'GOGL'), 'buy', 10);
select place_market_order((select id from assets where symbol = 'GOGL'), 'sell', 10);

create temp table r (label text primary key, receipt jsonb);
insert into r values ('lev', open_leveraged_position(
  (select id from assets where symbol = 'GOGL'), 'long', 10, 1000));

-- ---------------------------------------------------------------------------
-- Personal feed: the open position shows up while still open.
-- ---------------------------------------------------------------------------
select is((select count(*)::int from get_my_recent_trades(50)
            where kind = 'leverage'), 1,
  'an open leveraged position appears in your own activity');
select is((select status from get_my_recent_trades(50) where kind = 'leverage'),
  'open', 'and it is reported as open, not filled');
select ok((select count(*) from get_my_recent_trades(50) where kind = 'spot') >= 2,
  'spot orders still appear alongside it');

-- ---------------------------------------------------------------------------
-- Close it in profit, then check the P/L reaches both feeds.
-- ---------------------------------------------------------------------------
update public.assets set current_price = 200 where symbol = 'GOGL';
insert into r values ('close', close_leveraged_position(
  (select (receipt ->> 'position_id')::uuid from r where label = 'lev')));

select is(
  (select realized_pnl from get_my_recent_trades(50) where kind = 'leverage'),
  (select realized_pnl from leveraged_positions
    where id = (select (receipt ->> 'position_id')::uuid from r where label = 'lev')),
  'the leveraged close carries its realized P/L into your activity feed');

select ok((select realized_pnl from get_my_recent_trades(50)
            where kind = 'leverage') > 0,
  'a winning leveraged trade reports a profit, not null');

select is(
  (select cost_basis from get_my_recent_trades(50) where kind = 'leverage'),
  1000::numeric,
  'cost basis for a leveraged row is the margin staked (return is on stake)');

select is((select status from get_my_recent_trades(50) where kind = 'leverage'),
  'closed', 'status flips to closed');

-- A closed position must be dated by its CLOSE, not its open, or a position
-- held for hours resurfaces at the bottom of the feed the moment it resolves.
-- (now() is frozen inside a pgTAP transaction, so backdate the open to make
-- the two timestamps actually differ.)
update public.leveraged_positions set opened_at = now() - interval '2 hours'
 where id = (select (receipt ->> 'position_id')::uuid from r where label = 'lev');
select ok(
  (select at from get_my_recent_trades(50) where kind = 'leverage')
    > now() - interval '1 minute',
  'a closed position is dated by its close, not its open');

-- ---------------------------------------------------------------------------
-- Public Compete feed: closes and liquidations are now visible.
-- ---------------------------------------------------------------------------
select is((select count(*)::int from get_recent_activity(100)
            where kind = 'leverage_close'), 1,
  'the public feed shows how a leveraged bet ENDED, not just that it opened');

-- A liquidation is the loudest event in the game; make sure it is labelled.
update public.assets set current_price = 182.50, flow = 0 where symbol = 'GOGL';
insert into r values ('doomed', open_leveraged_position(
  (select id from assets where symbol = 'GOGL'), 'long', 10, 1000));
update public.assets set current_price = 150 where symbol = 'GOGL';
select game.process_leveraged_positions();

select is((select count(*)::int from get_recent_activity(100)
            where kind = 'liquidation'), 1,
  'a liquidation is surfaced as its own kind in the public feed');

select * from finish();
rollback;
