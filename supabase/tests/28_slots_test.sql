-- ============================================================================
-- Slots: honest published odds, a real cash sink, and — the important one —
-- complete isolation from the season leaderboard.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));

select plan(14);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'authenticated', 'authenticated', 'lucky@example.test',
        '{"display_name": "Lucky"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);
insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'mission_reward', 100000, 'test');

-- ---------------------------------------------------------------------------
-- The odds. Computed in closed form from the payout table, so an accidental
-- edit that turns the machine into a money printer fails here and nowhere else.
-- ---------------------------------------------------------------------------
select ok(game.slot_rtp() < 1,
  'the house has an edge — slots is a cash SINK, not a faucet');
select ok(game.slot_rtp() between 0.85 and 0.95,
  'but a fair one: return to player sits in the 85-95% band');
select ok((select max(pay3) from slot_symbols) >= 100,
  'there is a jackpot worth chasing');

-- ---------------------------------------------------------------------------
-- Bet validation.
-- ---------------------------------------------------------------------------
select is(spin_slots(1) ->> 'reason', 'minimum bet is 10',
  'dust bets are rejected');
select is(spin_slots(999999) ->> 'reason', 'maximum bet is 5000',
  'the machine cannot be used to move a fortune in one spin');

create temp table r (label text primary key, receipt jsonb);
insert into r values ('spin', spin_slots(100));
select is(receipt ->> 'status', 'spun', 'a valid bet spins')
  from r where label = 'spin';
select is(jsonb_array_length(receipt -> 'reels'), 3, 'three reels are returned')
  from r where label = 'spin';

-- ---------------------------------------------------------------------------
-- Every spin is fully accounted for in the ledger — the stake as its own debit
-- and any payout as its own credit, so "what did I risk" is answerable.
-- ---------------------------------------------------------------------------
select is(
  (select cash_delta from transactions
    where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and type = 'arcade_bet'),
  -100.00::numeric(18,2), 'the stake leaves as its own ledger row');

select is(
  (select net_pnl from user_arcade where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  (select (receipt ->> 'net')::numeric(18,2) from r where label = 'spin'),
  'arcade P/L tracks the spin exactly');

select is((select count(*)::int from slot_spins
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 1,
  'the spin is recorded for the history strip');

select is((select count(*)::int from game.reconcile_ledger()), 0,
  'the ledger reconciles after arcade flows');

-- ---------------------------------------------------------------------------
-- THE IMPORTANT ONE: winning or losing at slots must not move the season
-- figure. Force a large arcade win and confirm trading_net_worth is unmoved
-- while total net worth rises by exactly that amount.
-- ---------------------------------------------------------------------------
select game.market_tick();

create temp table before as
  select trading_net_worth as t, net_worth as n, business_equity as b
    from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

-- A $50,000 jackpot, applied exactly the way spin_slots would.
insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'arcade_win', 50000, 'slots');
update public.user_arcade set net_pnl = net_pnl + 50000
 where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

select game.market_tick();

select is(
  (select trading_net_worth from profiles
    where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  (select t from before),
  'a $50k jackpot does NOT move the season figure');

select is(
  (select net_worth from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  (select n + 50000 from before),
  '...but it does count toward total net worth');

-- Symmetric: a loss must not flatter your season score either.
create temp table before2 as
  select trading_net_worth as t from profiles
   where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'arcade_bet', -20000, 'slots');
update public.user_arcade set net_pnl = net_pnl - 20000
 where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

select game.market_tick();

select is(
  (select trading_net_worth from profiles
    where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  (select t from before2),
  'losing $20k at slots does not dent the season figure either');

select * from finish();
rollback;
