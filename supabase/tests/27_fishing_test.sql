-- ============================================================================
-- The Fishery: idle accrual caps, bait gates active play, gear is capital,
-- and the payout economy stays inside its intended band.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));

select plan(24);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'authenticated', 'authenticated', 'finn@example.test',
        '{"display_name": "Finn"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);

-- ---------------------------------------------------------------------------
-- Signup provisioning.
-- ---------------------------------------------------------------------------
select is((select boat_code from user_fishery
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  'boat_row', 'a new player is given a rowboat automatically');

-- ---------------------------------------------------------------------------
-- Idle accrual is capped by the hold. This is the whole design: it fills and
-- then WAITS, which is what makes coming back worth anything.
-- ---------------------------------------------------------------------------
update public.user_fishery set last_accrued_at = now() - interval '30 days'
 where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select game.accrue_fishing('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

select is((select count(*)::int from fishery_hold
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  (select hold_capacity from fishing_gear where code = 'boat_row'),
  'a month away fills the hold exactly to capacity, never past it');

-- ...and the clock advances for everyone, so a full hold cannot bank credit
-- and then dump a windfall the moment it is emptied.
select ok((select last_accrued_at from user_fishery
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
          > now() - interval '1 minute',
  'the accrual clock advances even when the hold was already full');

delete from public.fishery_hold where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select game.accrue_fishing('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
select is((select count(*)::int from fishery_hold
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 0,
  'an emptied hold does not instantly refill from banked time');

-- ---------------------------------------------------------------------------
-- THE PRODUCTION PATH: many small cron runs, not one big gap.
--
-- The original accrual floored elapsed*rate to whole fish and then threw the
-- remainder away with the clock. A 5-minute cron run on a 2/hour boat scores
-- floor(0.167) = 0, so progress reset every run and the hold NEVER filled.
-- The single-30-day-gap assertions above all passed while idle fishing was
-- completely dead. Replay the real cadence.
-- ---------------------------------------------------------------------------
delete from public.fishery_hold where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
update public.user_fishery set last_accrued_at = now()
 where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

do $$
declare i int;
begin
  -- 72 runs x 5 minutes = 6 hours, which is one full hold on any boat.
  for i in 1..72 loop
    update public.user_fishery
       set last_accrued_at = last_accrued_at - interval '5 minutes'
     where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    perform game.accrue_fishing('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  end loop;
end $$;

select ok((select count(*) from fishery_hold
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') >= 10,
  'six hours of 5-minute cron runs fills the hold (sub-fish remainder carries)');

-- ...and it still cannot overfill or bank time beyond the cap.
do $$
declare i int;
begin
  for i in 1..72 loop
    update public.user_fishery
       set last_accrued_at = last_accrued_at - interval '5 minutes'
     where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    perform game.accrue_fishing('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  end loop;
end $$;

select is((select count(*)::int from fishery_hold
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  (select hold_capacity from fishing_gear where code = 'boat_row'),
  'a further six hours cannot push the hold past capacity');

delete from public.fishery_hold where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select game.accrue_fishing('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
select is((select count(*)::int from fishery_hold
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 0,
  'the time spent full is forfeited, not redeemed as a windfall on sale');

-- ---------------------------------------------------------------------------
-- A rowboat only reaches shallow water. Deeper tiers are the real upgrade.
-- ---------------------------------------------------------------------------
update public.user_fishery set last_accrued_at = now() - interval '30 days'
 where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select game.accrue_fishing('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
select is((select count(*)::int from fishery_hold h
            join fish_species s on s.code = h.species_code
           where h.user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
             and s.min_boat_tier > 1), 0,
  'a rowboat never lands a fish from deeper water than it can reach');

-- ---------------------------------------------------------------------------
-- Selling: one payout, through the ledger, and the hold empties.
-- ---------------------------------------------------------------------------
create temp table r (label text primary key, receipt jsonb);
insert into r values ('sold', sell_catch());

select is(receipt ->> 'status', 'sold', 'the hold sells') from r where label = 'sold';
select is((select count(*)::int from fishery_hold
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 0,
  'selling empties the hold');
select is(
  (select cash_delta from transactions
    where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and type = 'fishing_sale'),
  (select (receipt ->> 'total')::numeric(18,2) from r where label = 'sold'),
  'the payout goes through the ledger, not a direct balance write');
select ok((select lifetime_value from user_fishery
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') > 0,
  'lifetime earnings accumulate');
select is(receipt ->> 'status', 'empty', 'selling an empty hold is a no-op')
  from (select sell_catch() as receipt) x;

-- ---------------------------------------------------------------------------
-- Bait gates active play — it is time-limited, never cash-limited.
-- ---------------------------------------------------------------------------
update public.user_fishery set bait = 0, bait_updated_at = now()
 where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is((select cast_line() ->> 'reason'), 'out of bait',
  'no bait, no cast');

update public.user_fishery
   set bait = 0, bait_updated_at = now() - interval '1 hour'
 where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(game.refresh_bait('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 12,
  'bait regenerates on the clock: one every 5 minutes for an hour');

insert into r values ('cast', cast_line());
select is(receipt ->> 'status', 'caught', 'a cast with bait lands a fish')
  from r where label = 'cast';
select is((select bait from user_fishery
            where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 11,
  'casting spends exactly one bait');

-- ---------------------------------------------------------------------------
-- Gear is capital, bought one tier at a time.
-- ---------------------------------------------------------------------------
insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'mission_reward', 50000, 'test');

select is((select buy_fishing_gear('boat_factory') ->> 'reason'),
  'upgrade one tier at a time',
  'you cannot skip straight to the factory ship');

insert into r values ('gear', buy_fishing_gear('boat_skiff'));
select is(receipt ->> 'status', 'bought', 'the next tier up is purchasable')
  from r where label = 'gear';

-- Capital, not consumption: it lands in business_equity, so total net worth is
-- unchanged by the purchase (the season figure drops, exactly like committing
-- capital to a company or a property).
select game.market_tick();
select is(
  (select business_equity from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  2500.00::numeric(18,2),
  'gear value lands on the business track, off the season leaderboard');

-- ---------------------------------------------------------------------------
-- The economy stays inside its band. If a catalog edit ever makes fishing a
-- better earner than trading, this is what says so.
-- ---------------------------------------------------------------------------
select ok(
  (select sum(s.rarity_weight * s.value_per_kg
              * (s.min_weight_kg + s.max_weight_kg) / 2)
        / sum(s.rarity_weight)
     from public.fish_species s) between 5 and 20,
  'expected value of a fully-unlocked catch stays in the $5-20 band');

-- Every boat should fill its hold in roughly the same time, so the check-in
-- rhythm is the same at every tier and upgrading buys a bigger payout per
-- visit rather than a different schedule.
select ok(
  (select max(hold_capacity / catch_per_hour) - min(hold_capacity / catch_per_hour)
     from public.fishing_gear where kind = 'boat' and catch_per_hour > 0) < 1,
  'every boat fills its hold within an hour of the same pace');

-- A tier-1 hold has to be worth selling or nobody ever starts, and the top
-- tier has to stay a side earner rather than out-running the markets.
select ok(
  (select g.hold_capacity
          * (select sum(s.rarity_weight * s.value_per_kg
                        * (s.min_weight_kg + s.max_weight_kg) / 2)
                  / sum(s.rarity_weight)
               from public.fish_species s where s.min_boat_tier <= g.tier)
     from public.fishing_gear g where g.code = 'boat_row') between 25 and 150,
  'a starter hold is worth enough to bother selling');

select ok(
  (select g.hold_capacity
          * (select sum(s.rarity_weight * s.value_per_kg
                        * (s.min_weight_kg + s.max_weight_kg) / 2)
                  / sum(s.rarity_weight)
               from public.fish_species s where s.min_boat_tier <= g.tier)
     from public.fishing_gear g where g.code = 'boat_factory') < 1500,
  'the endgame hold stays a side earner, not a money printer');

select * from finish();
rollback;
