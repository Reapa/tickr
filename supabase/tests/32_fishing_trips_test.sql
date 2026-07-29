-- ============================================================================
-- Fishing trips: the spot decides what is possible, the fight decides whether
-- you keep it, the well is not sellable until you bank it, and no amount of
-- cash buys a licence.
--
-- The load-bearing assertions here are the ones about the TRUST BOUNDARY. The
-- client reports the outcome of its own fight, so the tests that matter are
-- the ones proving what a forged report cannot do: it cannot arrive faster
-- than the fight could be played, it cannot invent a fish the server did not
-- roll, and it cannot claim a skill bonus larger than the clamp.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));

select plan(40);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'authenticated', 'authenticated', 'skipper@example.test',
        '{"display_name": "Skipper"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "role": "authenticated"}', true);

create temp table r (label text primary key, receipt jsonb);

-- Idle accrual would otherwise fill the hold underneath us and change counts.
update public.user_fishery
   set last_accrued_at = now(), bait = 30, bait_updated_at = now()
 where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

-- ---------------------------------------------------------------------------
-- Spots are gated by the boat, and casting without a trip is not a thing.
-- ---------------------------------------------------------------------------
select is(start_trip('trench') ->> 'reason', 'The Trench needs a tier-5 boat',
  'a rowboat cannot sail to the Trench');

select is(cast_line() ->> 'reason', 'pick a spot and start a trip',
  'casting outside a trip is refused');

insert into r values ('trip', start_trip('harbour'));
select is(receipt ->> 'status', 'started', 'a rowboat can fish the harbour')
  from r where label = 'trip';

select is(start_trip('harbour') ->> 'reason', 'you are already out on the water',
  'only one trip can be active at a time');

-- ---------------------------------------------------------------------------
-- A cast HOOKS something. It spends bait, hands back fight parameters, and
-- deliberately does not say what is on the line — that is the whole reason to
-- fight it rather than read a result card.
-- ---------------------------------------------------------------------------
insert into r values ('cast', cast_line());
select is(receipt ->> 'status', 'hooked', 'a cast hooks a fish')
  from r where label = 'cast';
select is((select bait from user_fishery
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'), 29,
  'casting spends exactly one bait');
select ok((select receipt -> 'fight' ? 'stamina_ms' and receipt -> 'fight' ? 'band_low'
             from r where label = 'cast'),
  'the cast returns the fight the client has to play');
select ok((select not (receipt ? 'species') and not (receipt ? 'value')
             from r where label = 'cast'),
  'the cast never reveals the species or its value');

select is(cast_line() ->> 'reason', 'you already have one on the line',
  'you cannot cast a second line while one is hooked');

-- ---------------------------------------------------------------------------
-- THE TRUST BOUNDARY. A resolve that arrives sooner than the fight could
-- physically have been played is not a fast player, it is a forged call.
-- ---------------------------------------------------------------------------
select is(
  (select resolve_encounter(id, true, 1.0) ->> 'status' from public.fishing_encounters
    where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and status = 'hooked'),
  'lost',
  'a resolve faster than the fight itself is rejected, not paid out');

select is((select status from public.fishing_encounters
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
            order by hooked_at desc limit 1), 'expired',
  'the forged encounter is burned, so it cannot be retried');

-- ---------------------------------------------------------------------------
-- A real fight: land it, and it goes into the LIVE WELL — not into anything
-- you can sell yet.
-- ---------------------------------------------------------------------------
create or replace function pg_temp.hook_and_wait()
returns public.fishing_encounters
language plpgsql as $$
declare v_enc public.fishing_encounters%rowtype;
begin
  perform public.cast_line();
  select * into v_enc from public.fishing_encounters
   where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and status = 'hooked';
  -- Stand in for the seconds the player would have spent on the reel.
  update public.fishing_encounters
     set hooked_at = hooked_at - interval '20 seconds'
   where id = v_enc.id
  returning * into v_enc;
  return v_enc;
end $$;

create temp table enc as select * from pg_temp.hook_and_wait();

insert into r values ('land',
  (select resolve_encounter(id, true, 0.2) from enc));
select is(receipt ->> 'status', 'landed', 'a fought fish is landed')
  from r where label = 'land';
select ok((select (receipt ? 'name') and (receipt ? 'value') from r where label = 'land'),
  'landing is when the species and its value are finally revealed');

select is((select count(*)::int from fishery_hold
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
              and trip_id is not null), 1,
  'the fish goes into the live well, tagged to the trip');

select is((get_my_fishery() -> 'trip' ->> 'well_count'), '1',
  'the trip reports what is in the well');
select is((get_my_fishery() ->> 'hold_count'), '0',
  'a well fish is NOT counted as sellable hold');
select is(sell_catch() ->> 'status', 'empty',
  'selling mid-trip cannot cash out the well behind your back');

-- A landed fish is exactly the fish the server escrowed at cast time. A client
-- that claims otherwise changes nothing, because it was never asked.
select is((select h.species_code || ':' || h.weight_kg from fishery_hold h
            where h.trip_id is not null),
          (select e.species_code || ':' || e.weight_kg from enc e),
  'the landed fish is the one the server rolled, not one the client named');

-- ...and the skill bonus is a clamp, not a client input.
select is((select value from fishery_hold where trip_id is not null),
          (select value from enc),
  'a scrappy fight pays the base value');

-- ---------------------------------------------------------------------------
-- A clean fight pays the clamped premium, and nothing above it.
-- ---------------------------------------------------------------------------
truncate enc;
insert into enc select * from pg_temp.hook_and_wait();
select is((select resolve_encounter(id, true, 0.99) ->> 'perfect' from enc), 'true',
  'a clean fight is recognised');
-- Keyed on encounter_id, not caught_at: every fish landed in one transaction
-- shares a caught_at, because now() is the transaction clock.
select is(
  (select h.value from fishery_hold h join enc e on e.id = h.encounter_id),
  (select round(e.value * 1.25, 2) from enc e),
  'a clean fight pays exactly the clamped 1.25x, however good the client says it was');

select is((select streak from fishing_trips
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and status = 'active'), 2,
  'consecutive landings build the streak');

-- ---------------------------------------------------------------------------
-- Losing the fight is what puts the "push your luck" in the trip: it resets
-- the bonus AND spills the smallest fish already in the well.
-- ---------------------------------------------------------------------------
truncate enc;
insert into enc select * from pg_temp.hook_and_wait();
insert into r values ('lose', (select resolve_encounter(id, false, 0.1) from enc));
select is(receipt ->> 'status', 'lost', 'a snapped line loses the fish')
  from r where label = 'lose';
select is(receipt ->> 'spilled', 'true', 'and takes one out of the well with it')
  from r where label = 'lose';
select is((select streak from fishing_trips
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and status = 'active'), 0,
  'a loss resets the streak');
select is((select count(*)::int from fishery_hold
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and trip_id is not null), 1,
  'the well is one fish lighter');

-- ---------------------------------------------------------------------------
-- Supplies: bought with cash that is BURNED (the fishery's only real sink),
-- carried onto the trip, and a spare line buys back exactly one snap.
-- ---------------------------------------------------------------------------
insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'mission_reward', 8000000, 'test');

select is(buy_fishing_supply('spare_line', 1) ->> 'status', 'bought',
  'supplies are purchasable');
select ok(
  (select cash_delta < 0 from transactions
    where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and type = 'fishing_supply'),
  'supplies debit cash through the ledger and never come back as equity');
select is(use_fishing_supply('spare_line') ->> 'status', 'used',
  'a supply is loaded onto the active trip');

truncate enc;
insert into enc select * from pg_temp.hook_and_wait();
insert into r values ('saved', (select resolve_encounter(id, false, 0.1) from enc));
select is(receipt ->> 'saved', 'true', 'the spare line saves the run')
  from r where label = 'saved';
select is((select count(*)::int from fishery_hold
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and trip_id is not null), 1,
  'a saved snap spills nothing');

-- ---------------------------------------------------------------------------
-- Banking: the haul bonus rides on the BEST streak of the trip, so pushing
-- your luck and then losing still pays for the run you put together.
-- ---------------------------------------------------------------------------
insert into r values ('bank', bank_haul());
select is(receipt ->> 'haul_bonus', '1.24',
  'the haul bonus is priced off the best streak of the trip, not the last one')
  from r where label = 'bank';
select is((select count(*)::int from fishery_hold
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and trip_id is not null), 0,
  'banking clears the well');
select ok((get_my_fishery() ->> 'hold_count')::int > 0,
  'and the fish become sellable hold');

-- ---------------------------------------------------------------------------
-- The spot IS the species table. A harbour trip cannot land deep water, no
-- matter how long you sit there.
-- ---------------------------------------------------------------------------
select start_trip('harbour');
do $$
declare i int; v_trip uuid;
begin
  select id into v_trip from public.fishing_trips
   where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and status = 'active';
  for i in 1..60 loop
    perform game.roll_encounter(v_trip);
  end loop;
end $$;

select is(
  (select count(*)::int from public.fishing_encounters e
     join public.fish_species s on s.code = e.species_code
    where e.user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      and s.code not in (select species_code from public.fishing_spot_species
                          where spot_code = 'harbour')), 0,
  'sixty harbour casts never turn up a fish that does not live there');

-- ---------------------------------------------------------------------------
-- LICENCES. This is the answer to "it took me 10 mins to unlock everything":
-- the player below is holding $8m and still cannot buy the boat.
-- ---------------------------------------------------------------------------
update public.user_fishery set boat_code = 'boat_factory'
 where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

select ok((buy_fishing_gear('boat_research') ->> 'reason') like 'licence: log 9 species%',
  'cash alone does not buy the Research Vessel');

insert into public.user_fish_log (user_id, species_code, catches, best_kg)
select 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', code, 1, min_weight_kg
  from public.fish_species where rarity <> 'legendary'
on conflict do nothing;

select is(buy_fishing_gear('boat_research') ->> 'status', 'bought',
  'the licence is earned from the catch log, and then the money works');

select is(buy_fishing_gear('boat_ice') ->> 'reason', 'licence: land a legendary fish first',
  'the Ice Runner needs a legendary on the board, not a bigger balance');

-- ---------------------------------------------------------------------------
-- Economy guards for the new tiers: the check-in rhythm is unchanged, and the
-- haul bonus cannot be stacked into a money printer.
-- ---------------------------------------------------------------------------
select ok(
  (select max(hold_capacity / catch_per_hour) - min(hold_capacity / catch_per_hour)
     from public.fishing_gear where kind = 'boat' and catch_per_hour > 0) < 1,
  'the prestige boats keep the same six-hour fill rhythm as every other tier');

select ok(
  (select max(haul_cap) from public.fishing_spots)
    <= game.config_numeric('fishing_haul_cap'),
  'no spot can pay a haul bonus above the global clamp');

select * from finish();
rollback;
