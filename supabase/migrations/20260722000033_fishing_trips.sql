-- ============================================================================
-- The Fishery, part two: trips, the fight, and a ladder you cannot speedrun
--
-- Two complaints from the owner, both fair:
--
--   1. "It took me 10 mins to unlock everything."
--      The gear ladder was $124k of pure cash across seven items. Anyone with
--      real trading money cleared it in one sitting and the shop was then dead
--      forever. Fixed three ways: prestige tiers priced for a late-game
--      balance sheet, LICENCES that cash cannot buy (you have to have logged
--      the species — see `req_*` on fishing_gear), and consumable supplies so
--      cash always has somewhere to go.
--
--   2. "The fishing game is very boring... need some sort of active gameplay."
--      Casting was one button that resolved instantly. It is now a trip:
--
--        pick a spot  ->  cast  ->  wait for the bite (variable delay)
--          ->  set the hook inside a reaction window
--          ->  fight it: keep line tension inside a band while it runs
--          ->  land it into the live well, or lose it
--          ->  bank the well, or push your luck for a bigger haul bonus
--
-- WHERE THE TRUST BOUNDARY SITS. The server rolls the fish, its weight and its
-- value at CAST time and escrows them in `fishing_encounters` — the client is
-- never told what it hooked until it is resolved, and never computes value.
-- What the client does report is the outcome of the fight it just played. That
-- is deliberately trusted, because a skill game whose skill is evaluated on the
-- server is not a skill game. The exposure is bounded on every side:
--
--   * casts are bait-gated, and bait is on a server clock, so a perfect
--     cheater lands exactly as many fish per hour as a perfect player;
--   * the escrowed fish is already rolled, so claiming "landed" only ever wins
--     the fish the server had already decided on;
--   * the skill bonus is a value multiplier clamped server-side
--     (`fishing_perfect_bonus`, 1.25x) — there is no unbounded upside;
--   * a resolve arriving faster than the fight could physically be played is
--     rejected outright.
--
-- The ceiling on cheating is therefore "plays like an expert", which is the
-- correct ceiling for a mini-game that pays pocket money on the business track.
-- Nothing here touches the season leaderboard.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Config. Every number that shapes a fight or a haul lives here.
-- ----------------------------------------------------------------------------
insert into public.game_config (key, value, description) values
  ('fishing_haul_step',        '0.12', 'Haul bonus added per consecutive fish landed in a trip.'),
  ('fishing_haul_cap',         '2.00', 'Hard ceiling on the trip haul multiplier.'),
  ('fishing_trip_hours',       '6',    'An abandoned trip auto-banks after this many hours.'),
  ('fishing_encounter_seconds','90',   'How long a hooked fish waits for a resolve before it is gone.'),
  ('fishing_perfect_bonus',    '1.25', 'Value multiplier for a clean fight. The ONLY thing player '
                                       'skill can add, and it is clamped here.'),
  ('fishing_perfect_threshold','0.75', 'Fraction of the fight spent in the tension band to count as clean.')
on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- 2. Ledger: supplies are consumption, not capital. Unlike a boat, chum is
--    burned — the cash leaves net worth entirely, which makes it the fishery's
--    only real sink and the reason a maxed-out player still has a reason to
--    spend.
-- ----------------------------------------------------------------------------
alter table public.transactions drop constraint transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in (
    'starting_grant', 'trade_buy', 'trade_sell', 'class_unlock',
    'mission_reward', 'challenge_reward', 'season_reward',
    'margin_open', 'margin_close', 'daily_reward', 'passive_income',
    'company_invest', 'company_sale', 'property_invest', 'property_sale',
    'fishing_gear', 'fishing_sale', 'fishing_supply',
    -- Carried over from migration 28. Rebuilding this constraint from an
    -- older copy of the list silently un-declares whatever was added since,
    -- and the only thing that notices is another feature's test suite.
    'arcade_bet', 'arcade_win'
  ));
alter table public.transactions add constraint transactions_fishing_supply_debits
  check (type <> 'fishing_supply' or (cash_delta < 0 and qty_delta = 0));

-- ----------------------------------------------------------------------------
-- 3. Fishing spots — the reason a cast is a decision rather than a repeat.
--
-- A spot IS its species table: `fishing_spot_species` lists exactly what swims
-- there and re-weights it. Deep water is not "the same fish but more of them",
-- it is a different table with a longer fight and a shorter trip.
-- ----------------------------------------------------------------------------
create table public.fishing_spots (
  code           text primary key,
  name           text not null,
  min_boat_tier  int not null default 1,
  trip_casts     int not null check (trip_casts > 0),
  fight_scale    numeric not null default 1 check (fight_scale > 0),
  haul_cap       numeric not null default 1.5 check (haul_cap >= 1),
  blurb          text not null default '',
  sort_order     int not null default 0
);

insert into public.fishing_spots
  (code, name, min_boat_tier, trip_casts, fight_scale, haul_cap, blurb, sort_order) values
  ('harbour',    'The Harbour',   1, 12, 0.70, 1.40,
   'Flat water and forgiving fish. Nothing here will break your line.', 1),
  ('reef',       'The Reef',      2, 10, 0.90, 1.60,
   'Structure everywhere. Good fish, and plenty to snag a line on.', 2),
  ('open_water', 'Open Water',    3,  9, 1.15, 1.80,
   'No cover, no bottom, and the first place a rare fish shows up.', 3),
  ('canyon',     'The Canyon',    4,  7, 1.45, 2.00,
   'A shelf that drops away to nothing. Long fights, big animals.', 4),
  ('trench',     'The Trench',    5,  6, 1.75, 2.00,
   'Where the impossible things live. Six casts. Make them count.', 5),
  ('polar',      'The Ice Shelf', 7,  6, 1.90, 2.00,
   'Cold enough to stiffen a reel. Almost nothing else fishes here.', 6);

create table public.fishing_spot_species (
  spot_code    text not null references public.fishing_spots (code) on delete cascade,
  species_code text not null references public.fish_species (code) on delete cascade,
  weight_mult  numeric not null default 1 check (weight_mult > 0),
  primary key (spot_code, species_code)
);

insert into public.fishing_spot_species (spot_code, species_code, weight_mult) values
  ('harbour', 'sardine', 1.5), ('harbour', 'herring', 1.5),
  ('harbour', 'mackerel', 1.0), ('harbour', 'cod', 0.6),

  ('reef', 'mackerel', 1.0), ('reef', 'cod', 1.0), ('reef', 'seabass', 1.6),
  ('reef', 'snapper', 1.6), ('reef', 'salmon', 1.2),

  ('open_water', 'herring', 0.8), ('open_water', 'cod', 0.8),
  ('open_water', 'salmon', 1.0), ('open_water', 'tuna', 1.8),
  ('open_water', 'halibut', 1.6), ('open_water', 'swordfish', 1.5),

  ('canyon', 'tuna', 1.2), ('canyon', 'halibut', 1.2), ('canyon', 'swordfish', 1.4),
  ('canyon', 'marlin', 2.5), ('canyon', 'squid', 2.5),

  ('trench', 'swordfish', 0.5), ('trench', 'marlin', 1.5), ('trench', 'squid', 2.0),
  ('trench', 'greatwhite', 4.0), ('trench', 'koi', 1.0), ('trench', 'coelacanth', 5.0),

  ('polar', 'tuna', 1.0), ('polar', 'halibut', 2.0), ('polar', 'greatwhite', 6.0),
  ('polar', 'koi', 3.0), ('polar', 'coelacanth', 4.0);

-- ----------------------------------------------------------------------------
-- 4. Supplies — the permanent cash sink.
--
-- Bought with cash and BURNED, so unlike gear this money does not come back as
-- business equity. That is the point: it is the only thing in the fishery a
-- fully-upgraded player can still spend on, and it is what makes a hard trip
-- to the Trench a decision with a price on it.
-- ----------------------------------------------------------------------------
create table public.fishing_supplies (
  code        text primary key,
  name        text not null,
  description text not null,
  price       numeric(18,2) not null check (price > 0),
  uses        int not null check (uses > 0),   -- casts (or saves) per unit bought
  sort_order  int not null default 0
);

insert into public.fishing_supplies (code, name, description, price, uses, sort_order) values
  ('chum',       'Bucket of Chum',
   'Draws the good stuff up. Triples the odds of a rare fish for 3 casts.',
   1200, 3, 1),
  ('live_bait',  'Live Bait',
   'Only the big ones bother. Biases the size roll upward for 3 casts.',
   2000, 3, 2),
  ('spare_line', 'Spare Line',
   'Snap once and keep the haul bonus. One save.',
   3500, 1, 3);

create table public.user_fishing_supplies (
  user_id uuid not null references public.profiles (id) on delete cascade,
  code    text not null references public.fishing_supplies (code),
  qty     int not null default 0 check (qty >= 0),
  primary key (user_id, code)
);
alter table public.user_fishing_supplies enable row level security;
create policy "own supplies readable" on public.user_fishing_supplies
  for select using (user_id = auth.uid());
grant select on public.user_fishing_supplies to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Prestige gear and licences.
--
-- The `req_*` columns are the actual answer to the speedrun. A licence is
-- earned from the catch log, so the only way to reach the Ice Shelf is to have
-- fished your way there — no balance clears it.
-- ----------------------------------------------------------------------------
alter table public.fishing_gear
  add column req_species_logged int not null default 0,
  add column req_legendary      boolean not null default false,
  add column req_best_kg        numeric not null default 0,
  add column req_label          text not null default '';

insert into public.fishing_gear
  (code, kind, tier, name, description, price, catch_per_hour, hold_capacity,
   rare_bonus, sort_order, req_species_logged, req_legendary, req_best_kg, req_label) values
  -- Boats 6-8 hold the same ~6h fill rhythm as every tier before them: an
  -- upgrade buys a bigger payout per visit, never a different schedule.
  ('boat_research', 'boat', 6, 'Research Vessel',
   'Sonar, a wet lab, and a licence to work water nobody charts.',
   250000, 13.0, 78, 1, 6,
   9, false, 0, 'Log 9 species'),
  ('boat_ice',      'boat', 7, 'Ice Runner',
   'A reinforced hull rated for the shelf. Opens the coldest water there is.',
   1200000, 17.0, 102, 1, 7,
   0, true, 0, 'Land a legendary'),
  ('boat_argosy',   'boat', 8, 'The Argosy',
   'The last boat you will ever buy, and everyone on the water knows it.',
   6000000, 22.0, 132, 1, 8,
   15, true, 0, 'Complete the catch log'),
  ('rod_titan',     'rod',  5, 'Titan Rig',
   'A gimballed fighting chair with a rod bolted to it.',
   120000, 0, 0, 4.0, 15,
   0, false, 60, 'Land a 60kg fish'),
  ('rod_abyssal',   'rod',  6, 'Abyssal Rod',
   'Nobody will tell you what the line is made of.',
   750000, 0, 0, 5.5, 16,
   12, false, 0, 'Log 12 species')
on conflict (code) do nothing;

-- ----------------------------------------------------------------------------
-- 6. Trips and encounters.
--
-- A trip owns a live well: fish landed during it sit in `fishery_hold` tagged
-- with the trip, which keeps the sell path and the hold cap exactly as they
-- were. Banking simply clears the tag and stamps the haul bonus into the
-- stored value, so `sell_catch` never learns that trips exist.
-- ----------------------------------------------------------------------------
create table public.fishing_trips (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  spot_code   text not null references public.fishing_spots (code),
  casts_used  int not null default 0,
  landed      int not null default 0,
  lost        int not null default 0,
  streak      int not null default 0,   -- consecutive landings; drives the bonus
  best_streak int not null default 0,
  chum_casts  int not null default 0,
  bait_casts  int not null default 0,   -- live bait remaining
  spare_lines int not null default 0,
  status      text not null default 'active' check (status in ('active','banked')),
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  haul_bonus  numeric,                  -- stamped at bank time, for the receipt
  haul_value  numeric(18,2)
);
create index fishing_trips_user_idx on public.fishing_trips (user_id, status);
create unique index fishing_trips_one_active
  on public.fishing_trips (user_id) where status = 'active';
alter table public.fishing_trips enable row level security;
create policy "own trips readable" on public.fishing_trips
  for select using (user_id = auth.uid());
grant select on public.fishing_trips to authenticated;

-- The escrow. A hooked fish is fully decided here — species, weight, value —
-- before the client is told anything beyond how hard it is going to pull.
create table public.fishing_encounters (
  id            uuid primary key default gen_random_uuid(),
  trip_id       uuid not null references public.fishing_trips (id) on delete cascade,
  user_id       uuid not null references public.profiles (id) on delete cascade,
  species_code  text not null references public.fish_species (code),
  weight_kg     numeric(10,2) not null,
  value         numeric(18,2) not null,
  fight         jsonb not null,
  min_fight_ms  int not null,
  status        text not null default 'hooked'
                check (status in ('hooked','landed','escaped','expired')),
  score         numeric,
  hooked_at     timestamptz not null default now(),
  expires_at    timestamptz not null,
  resolved_at   timestamptz
);
create index fishing_encounters_open_idx
  on public.fishing_encounters (user_id) where status = 'hooked';
alter table public.fishing_encounters enable row level security;
create policy "own encounters readable" on public.fishing_encounters
  for select using (user_id = auth.uid());
grant select on public.fishing_encounters to authenticated;

alter table public.fishery_hold
  add column trip_id uuid references public.fishing_trips (id) on delete set null,
  -- Provenance: which fight produced this fish. Idle catches leave it null.
  -- Worth the column because `caught_at` cannot identify a row — it defaults to
  -- now(), which is the TRANSACTION timestamp, so two fish landed in one call
  -- are indistinguishable by time.
  add column encounter_id uuid references public.fishing_encounters (id) on delete set null;
create index fishery_hold_trip_idx on public.fishery_hold (trip_id);

alter table public.user_fishery
  add column last_spot_code text references public.fishing_spots (code),
  add column trips_completed int not null default 0,
  add column best_haul numeric(18,2) not null default 0;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.fishing_trips;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 7. Catalog read paths.
--
-- Migration 29's rule, restated because it has already bitten this project
-- twice: a world-readable table needs RLS ENABLED plus a `using (true)` select
-- policy. A bare grant reads fine locally and returns [] through PostgREST on
-- the hosted project.
-- ----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['fishing_spots', 'fishing_spot_species', 'fishing_supplies']
  loop
    execute format('alter table public.%I enable row level security', t);
    if not exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = t and policyname = t || ' readable'
    ) then
      execute format('create policy %I on public.%I for select using (true)',
                     t || ' readable', t);
    end if;
    execute format('grant select on public.%I to anon, authenticated', t);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 8. Licences: computed from the catch log, never stored, so they can never
--    drift out of sync with what you have actually landed.
-- ----------------------------------------------------------------------------
create or replace function game.fishing_licence(p_user uuid)
returns table (species_logged int, has_legendary boolean, best_kg numeric)
language sql
stable
security definer
set search_path = public, game
as $$
  select count(*)::int,
         bool_or(s.rarity = 'legendary'),
         coalesce(max(l.best_kg), 0)
    from public.user_fish_log l
    join public.fish_species s on s.code = l.species_code
   where l.user_id = p_user;
$$;

-- ----------------------------------------------------------------------------
-- 9. Rolling an encounter.
--
-- Species comes from the SPOT's table, not the global one, so where you sail
-- decides what is possible. Chum multiplies the rare tilt; live bait skews the
-- size roll high by taking the better of two draws.
-- ----------------------------------------------------------------------------
create or replace function game.roll_encounter(p_trip uuid)
returns public.fishing_encounters
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_trip   public.fishing_trips%rowtype;
  v_spot   public.fishing_spots%rowtype;
  v_row    public.user_fishery%rowtype;
  v_rod    public.fishing_gear%rowtype;
  v_fish   public.fish_species%rowtype;
  v_bonus  numeric;
  v_u      numeric;
  v_weight numeric;
  v_value  numeric;
  v_scale  numeric := coalesce(game.config_numeric('fishing_value_scale'), 1);
  v_rel    numeric;   -- 0..1 size within the species range
  v_diff   numeric;   -- 0..1 overall fight difficulty
  v_rodt   int;
  v_out    public.fishing_encounters%rowtype;
  v_fight  jsonb;
  v_stam   int;
  v_str    numeric;   -- tension gained per second on the reel
  v_relax  numeric;   -- tension bled per second off the reel
  v_duty   numeric;   -- best achievable fraction of the fight spent reeling
  v_chall  numeric;   -- what fraction of that best you are required to hit
  v_runs   int;
  v_rundur numeric;  -- ms per run
  v_slip   numeric := 0.06;
begin
  select * into v_trip from public.fishing_trips where id = p_trip;
  select * into v_spot from public.fishing_spots where code = v_trip.spot_code;
  select * into v_row  from public.user_fishery where user_id = v_trip.user_id;
  select * into v_rod  from public.fishing_gear where code = v_row.rod_code;
  v_rodt := coalesce(v_rod.tier, 1);

  v_bonus := coalesce(v_rod.rare_bonus, 1)
             * coalesce(game.config_numeric('fishing_active_rare_bonus'), 1)
             * case when v_trip.chum_casts > 0 then 3 else 1 end;

  select s.* into v_fish
    from public.fishing_spot_species ss
    join public.fish_species s on s.code = ss.species_code
   where ss.spot_code = v_trip.spot_code
   order by -ln(1 - random())
            / (s.rarity_weight * ss.weight_mult
               * case when s.rarity = 'common' then 1 else v_bonus end)
   limit 1;
  if not found then return v_out; end if;

  -- Live bait: best of two draws, so the same fish shows up heavier.
  v_u := random();
  if v_trip.bait_casts > 0 then v_u := greatest(v_u, random()); end if;
  v_weight := round((v_fish.min_weight_kg
              + v_u * (v_fish.max_weight_kg - v_fish.min_weight_kg))::numeric, 2);
  v_value  := round((v_weight * v_fish.value_per_kg * v_scale)::numeric, 2);

  -- Difficulty blends absolute mass with rarity, then the spot stretches it.
  v_rel  := case when v_fish.max_weight_kg > v_fish.min_weight_kg
                 then (v_weight - v_fish.min_weight_kg)
                      / (v_fish.max_weight_kg - v_fish.min_weight_kg)
                 else 0.5 end;
  v_diff := least(1.0, greatest(0.0,
              0.65 * (ln(1 + v_weight) / ln(1 + 550))
            + 0.25 * (case v_fish.rarity when 'common' then 0.10 when 'uncommon' then 0.30
                                         when 'rare' then 0.55 when 'epic' then 0.80
                                         else 1.00 end)
            + 0.10 * v_rel));

  v_stam := round((6000 + 14000 * v_diff) * v_spot.fight_scale)::int;
  v_runs := (1 + floor(v_diff * 4))::int;
  -- A run has to be a fraction of the fight, not a fixed number of seconds.
  -- At a flat 900ms, two runs ate a quarter of a 7-second cod fight and a
  -- fifteenth of a 35-second shark fight — which made the beginner's fish the
  -- harshest thing in the game.
  v_rundur := least(1400, greatest(600, v_stam * 0.10));

  -- The fight is a duty-cycle problem. Reeling builds tension, easing off bleeds
  -- it, and the line snaps at 1.0 — so the best fraction of the fight you can
  -- possibly spend winding is relax / (strength + relax). Sizing the wind speed
  -- against that ceiling is what keeps every matchup honest without hand-tuning
  -- a difficulty number per species.
  v_str   := greatest(0.20, 0.35 + 0.55 * v_diff - 0.04 * (v_rodt - 1));
  v_relax := 0.45 + 0.10 * (v_rodt - 1);
  v_duty  := v_relax / (v_str + v_relax);

  -- ...and THIS is where the fish and the rod actually meet. `challenge` is the
  -- fraction of theoretical-perfect play the fight demands. A big animal pushes
  -- it toward 1.0 (no slack at all); every rod tier buys it back down. A hand
  -- line on a great white lands near 0.85 and will mostly lose, which is the
  -- correct answer; the Abyssal Rod drags the same fish to ~0.60 and makes it
  -- routine. Without this term every fight was equally hard and the whole rod
  -- ladder bought nothing.
  v_chall := least(0.92, greatest(0.42,
               0.50 + 0.35 * v_diff - 0.05 * (v_rodt - 1)));

  -- The whole fight, resolved into numbers the client can simply animate. A
  -- better rod widens the safe band, widens the hook window, bleeds tension
  -- faster and therefore winds faster — that is what $750k actually buys you.
  v_fight := jsonb_build_object(
    'bite_ms',        round(600 + random() * 3400)::int,
    'hook_window_ms', greatest(320, round(900 - 350 * v_diff + 90 * (v_rodt - 1))::int),
    'stamina_ms',     v_stam,
    'strength',       round(v_str, 3),
    'relax_rate',     round(v_relax, 3),
    -- Wind speed sized so a fight played at `challenge` of the ceiling just
    -- lands it. Runs are discounted twice over, because they cost both the
    -- line they drag off AND the seconds you cannot wind through them; without
    -- the second term `challenge` silently means something harsher on a short
    -- fight than a long one.
    'reel_rate',      round(((1 + v_runs * (v_rundur / 1000.0) * v_slip)
                             / (greatest(1.0, (v_stam - v_runs * v_rundur) / 1000.0)
                                * v_duty * v_chall))::numeric, 4),
    'challenge',      round(v_chall, 3),
    -- Line is only given back when the fish RUNS, never merely for easing off.
    -- That keeps the rule the player has to learn down to one sentence.
    'slip_rate',      v_slip,
    'run_ms',         round(v_rundur)::int,
    -- A better rod widens the band DOWNWARD. Widening it upward looked like the
    -- obvious reward and was actually a trap: it pushed band_high toward the
    -- snap at 1.0, leaving the best rod in the game about 100ms of headroom
    -- between "safe" and "gone" — under human reaction time, so the top rod
    -- snapped lines the hand line survived. The danger zone is now the same
    -- width for everyone and what you buy is forgiveness on the slack side.
    'band_low',       round(greatest(0.18, 0.35 - 0.03 * (v_rodt - 1))::numeric, 3),
    'band_high',      0.70,
    -- Above the band YOUR winding loads the line much faster. Without this the
    -- gap between band_high and a snap was just free winding time, and simply
    -- holding the button down beat playing the fight properly on small fish —
    -- which made the tension band decoration rather than a mechanic. It applies
    -- only to winding, never to a run: a surge is not something you chose, and
    -- multiplying it too turned every run into an unplayable coin flip.
    'over_mult',      1.6,
    -- What a run adds per second, and the single most important number here.
    -- Easing off during a run nets 0.75*strength - 0.45*relax, so surviving one
    -- is a contest between how hard the animal pulls and how much drag the rod
    -- has. That is deliberately STRUCTURAL rather than a matter of playing
    -- well: when the only difference between rods was how efficiently you had
    -- to play, a good enough player landed great whites on a hand line, and the
    -- rod ladder meant nothing. Now a run on an under-gunned rod nearly snaps
    -- the line on its own, and a rod bought for the fish shrugs it off.
    'surge_rate',     round((0.75 * v_str + 0.55 * v_relax)::numeric, 3),
    'runs',           v_runs,
    -- A shadow in the water, not a name. The species is withheld until it is
    -- in the boat, which is the entire reason to fight it.
    'shadow',         case when v_weight >= 60 then 'huge'
                           when v_weight >= 8  then 'big' else 'small' end,
    'difficulty',     round(v_diff, 3));

  insert into public.fishing_encounters
    (trip_id, user_id, species_code, weight_kg, value, fight, min_fight_ms, expires_at)
  values (p_trip, v_trip.user_id, v_fish.code, v_weight, v_value, v_fight,
          -- A resolve cannot legitimately arrive before the bite plus a token
          -- fight. Anything faster is a replayed or forged call.
          (v_fight ->> 'bite_ms')::int + 900,
          now() + make_interval(
            secs => coalesce(game.config_numeric('fishing_encounter_seconds'), 90)))
  returning * into v_out;

  return v_out;
end $$;

-- ----------------------------------------------------------------------------
-- 10. Trip lifecycle
-- ----------------------------------------------------------------------------

create or replace function game.bank_trip(p_trip uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_trip  public.fishing_trips%rowtype;
  v_spot  public.fishing_spots%rowtype;
  v_step  numeric := coalesce(game.config_numeric('fishing_haul_step'), 0.12);
  v_cap   numeric := coalesce(game.config_numeric('fishing_haul_cap'), 2.0);
  v_mult  numeric;
  v_count int;
  v_total numeric;
begin
  select * into v_trip from public.fishing_trips where id = p_trip for update;
  if v_trip.id is null or v_trip.status <> 'active' then
    return jsonb_build_object('status', 'rejected', 'reason', 'no trip to bank');
  end if;
  select * into v_spot from public.fishing_spots where code = v_trip.spot_code;

  -- The bonus rides on the BEST streak of the trip, not the streak you happen
  -- to end on. Otherwise the optimal play is to bank the instant you land one
  -- fish, and the push-your-luck decision evaporates.
  v_mult := least(least(1 + v_step * v_trip.best_streak, v_cap), v_spot.haul_cap);

  select count(*), coalesce(sum(value), 0) into v_count, v_total
    from public.fishery_hold where trip_id = p_trip;

  if v_count > 0 and v_mult > 1 then
    update public.fishery_hold
       set value = round(value * v_mult, 2)
     where trip_id = p_trip;
    select coalesce(sum(value), 0) into v_total
      from public.fishery_hold where trip_id = p_trip;
  end if;

  -- Clearing the tag merges the well into the ordinary hold, which is what
  -- keeps sell_catch ignorant of trips entirely.
  update public.fishery_hold set trip_id = null where trip_id = p_trip;

  update public.fishing_trips
     set status = 'banked', ended_at = now(),
         haul_bonus = v_mult, haul_value = v_total
   where id = p_trip;

  update public.user_fishery
     set trips_completed = trips_completed + 1,
         best_haul = greatest(best_haul, v_total),
         updated_at = now()
   where user_id = v_trip.user_id;

  return jsonb_build_object('status', 'banked', 'count', v_count, 'total', v_total,
                            'haul_bonus', v_mult, 'landed', v_trip.landed,
                            'lost', v_trip.lost, 'best_streak', v_trip.best_streak,
                            'spot', v_trip.spot_code);
end $$;

-- Auto-bank anything left running. A trip abandoned mid-session must not strand
-- the well behind the one-active-trip index forever, and closing a tab should
-- never cost a player the fish already in the boat.
create or replace function game.expire_fishing(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_hours numeric := coalesce(game.config_numeric('fishing_trip_hours'), 6);
  r record;
begin
  -- An unresolved hook is a lost fish: it costs the streak, but unlike a
  -- snapped line it never spills the well. A dropped connection must not be
  -- more expensive than actually losing the fight, or the honest play is to
  -- pull the plug whenever a fight is going badly.
  with gone as (
    update public.fishing_encounters
       set status = 'expired', resolved_at = now()
     where user_id = p_user and status = 'hooked' and expires_at < now()
    returning trip_id
  )
  update public.fishing_trips t
     set streak = 0, lost = t.lost + 1
   where t.id in (select trip_id from gone) and t.status = 'active';

  for r in
    select id from public.fishing_trips
     where user_id = p_user and status = 'active'
       and started_at < now() - make_interval(secs => v_hours * 3600)
  loop
    perform game.bank_trip(r.id);
  end loop;
end $$;

create or replace function public.start_trip(p_spot text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_spot public.fishing_spots%rowtype;
  v_row  public.user_fishery%rowtype;
  v_boat public.fishing_gear%rowtype;
  v_held int;
  v_trip public.fishing_trips%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if game.config_numeric('fishing_enabled') < 1 then
    return jsonb_build_object('status', 'rejected', 'reason', 'the fishery is closed');
  end if;

  perform game.ensure_fishery(v_user);
  perform game.expire_fishing(v_user);

  select * into v_spot from public.fishing_spots where code = p_spot;
  if not found then return jsonb_build_object('status', 'rejected', 'reason', 'no such spot'); end if;

  select * into v_row  from public.user_fishery where user_id = v_user for update;
  select * into v_boat from public.fishing_gear where code = v_row.boat_code;

  if v_boat.tier < v_spot.min_boat_tier then
    return jsonb_build_object('status', 'rejected',
      'reason', format('%s needs a tier-%s boat', v_spot.name, v_spot.min_boat_tier));
  end if;

  if exists (select 1 from public.fishing_trips
              where user_id = v_user and status = 'active') then
    return jsonb_build_object('status', 'rejected', 'reason', 'you are already out on the water');
  end if;

  perform game.accrue_fishing(v_user);
  select count(*) into v_held from public.fishery_hold where user_id = v_user;
  if v_held >= v_boat.hold_capacity then
    return jsonb_build_object('status', 'rejected', 'reason', 'the hold is full — sell your catch first');
  end if;

  insert into public.fishing_trips (user_id, spot_code) values (v_user, p_spot)
  returning * into v_trip;

  update public.user_fishery set last_spot_code = p_spot, updated_at = now()
   where user_id = v_user;

  return jsonb_build_object('status', 'started', 'trip_id', v_trip.id,
                            'spot', v_spot.code, 'spot_name', v_spot.name,
                            'trip_casts', v_spot.trip_casts);
end $$;

create or replace function public.bank_haul()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_trip uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select id into v_trip from public.fishing_trips
   where user_id = v_user and status = 'active';
  if v_trip is null then
    return jsonb_build_object('status', 'rejected', 'reason', 'you are not on a trip');
  end if;
  return game.bank_trip(v_trip);
end $$;

-- ----------------------------------------------------------------------------
-- 11. Casting, now a hook rather than a catch.
--
-- Signature keeps its old zero-argument form so nothing that called it breaks,
-- but the return is an ESCROW receipt: fight parameters and a shadow in the
-- water. What it is worth is decided here and withheld until it is landed.
-- ----------------------------------------------------------------------------
create or replace function public.cast_line()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user  uuid := auth.uid();
  v_row   public.user_fishery%rowtype;
  v_boat  public.fishing_gear%rowtype;
  v_trip  public.fishing_trips%rowtype;
  v_spot  public.fishing_spots%rowtype;
  v_held  int;
  v_enc   public.fishing_encounters%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if game.config_numeric('fishing_enabled') < 1 then
    return jsonb_build_object('status', 'rejected', 'reason', 'the fishery is closed');
  end if;

  perform game.ensure_fishery(v_user);
  perform game.expire_fishing(v_user);
  perform game.refresh_bait(v_user);

  select * into v_trip from public.fishing_trips
   where user_id = v_user and status = 'active' for update;
  if v_trip.id is null then
    return jsonb_build_object('status', 'rejected', 'reason', 'pick a spot and start a trip');
  end if;
  select * into v_spot from public.fishing_spots where code = v_trip.spot_code;

  if exists (select 1 from public.fishing_encounters
              where user_id = v_user and status = 'hooked') then
    return jsonb_build_object('status', 'rejected', 'reason', 'you already have one on the line');
  end if;

  if v_trip.casts_used >= v_spot.trip_casts then
    return jsonb_build_object('status', 'rejected', 'reason', 'that is the whole trip — bank the haul');
  end if;

  select * into v_row  from public.user_fishery where user_id = v_user for update;
  select * into v_boat from public.fishing_gear where code = v_row.boat_code;

  if v_row.bait < 1 then
    return jsonb_build_object('status', 'rejected', 'reason', 'out of bait', 'bait', v_row.bait);
  end if;

  select count(*) into v_held from public.fishery_hold where user_id = v_user;
  if v_held >= v_boat.hold_capacity then
    return jsonb_build_object('status', 'rejected', 'reason', 'the hold is full', 'bait', v_row.bait);
  end if;

  update public.user_fishery set bait = bait - 1, updated_at = now()
   where user_id = v_user;

  v_enc := game.roll_encounter(v_trip.id);
  if v_enc.id is null then
    update public.user_fishery set bait = bait + 1 where user_id = v_user;
    return jsonb_build_object('status', 'rejected', 'reason', 'nothing biting here');
  end if;

  update public.fishing_trips
     set casts_used = casts_used + 1,
         chum_casts = greatest(chum_casts - 1, 0),
         bait_casts = greatest(bait_casts - 1, 0)
   where id = v_trip.id;

  return jsonb_build_object(
    'status', 'hooked',
    'encounter_id', v_enc.id,
    'fight', v_enc.fight,
    'bait', v_row.bait - 1,
    'casts_used', v_trip.casts_used + 1,
    'trip_casts', v_spot.trip_casts,
    'expires_at', v_enc.expires_at);
end $$;

-- ----------------------------------------------------------------------------
-- 12. Resolving the fight.
--
-- The client reports how it went; the server decides what that is worth. See
-- the header for why this boundary sits here and what bounds the exposure.
-- ----------------------------------------------------------------------------
create or replace function public.resolve_encounter(
  p_encounter uuid,
  p_landed    boolean,
  p_score     numeric default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user    uuid := auth.uid();
  v_enc     public.fishing_encounters%rowtype;
  v_trip    public.fishing_trips%rowtype;
  v_fish    public.fish_species%rowtype;
  v_score   numeric;
  v_perfect boolean;
  v_value   numeric;
  v_elapsed numeric;
  v_spill   uuid;
  v_saved   boolean := false;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  select * into v_enc from public.fishing_encounters
   where id = p_encounter and user_id = v_user for update;
  if v_enc.id is null then
    return jsonb_build_object('status', 'rejected', 'reason', 'no such catch');
  end if;
  if v_enc.status <> 'hooked' then
    return jsonb_build_object('status', 'rejected', 'reason', 'already resolved');
  end if;

  select * into v_trip from public.fishing_trips where id = v_enc.trip_id for update;

  v_elapsed := extract(epoch from now() - v_enc.hooked_at) * 1000;

  -- Two clocks, two forgeries closed. Too fast is a resolve that was never
  -- played; too slow is a fight abandoned and reported later.
  if v_elapsed < v_enc.min_fight_ms or now() > v_enc.expires_at then
    update public.fishing_encounters
       set status = 'expired', resolved_at = now(), score = 0
     where id = v_enc.id;
    update public.fishing_trips
       set streak = 0, lost = lost + 1 where id = v_trip.id;
    return jsonb_build_object('status', 'lost', 'reason',
      case when now() > v_enc.expires_at then 'it broke off while you waited'
           else 'that line never went taut' end);
  end if;

  v_score := least(1, greatest(0, coalesce(p_score, 0)));

  if not p_landed then
    update public.fishing_encounters
       set status = 'escaped', resolved_at = now(), score = v_score
     where id = v_enc.id;

    -- A snap costs the run AND the smallest fish in the well. Spare line buys
    -- that back once — the reason to carry one into the Trench.
    if v_trip.spare_lines > 0 then
      v_saved := true;
      update public.fishing_trips
         set spare_lines = spare_lines - 1, lost = lost + 1
       where id = v_trip.id;
    else
      select id into v_spill from public.fishery_hold
       where trip_id = v_trip.id order by value asc limit 1;
      if v_spill is not null then
        delete from public.fishery_hold where id = v_spill;
      end if;
      update public.fishing_trips
         set streak = 0, lost = lost + 1 where id = v_trip.id;
    end if;

    return jsonb_build_object('status', 'lost', 'saved', v_saved,
      'spilled', (v_spill is not null),
      'reason', case when v_saved then 'the line went — your spare held it'
                     else 'it threw the hook and took a fish with it' end);
  end if;

  select * into v_fish from public.fish_species where code = v_enc.species_code;
  v_perfect := v_score >= coalesce(game.config_numeric('fishing_perfect_threshold'), 0.75);
  -- The ONE thing skill is worth, and it is clamped here rather than trusted.
  v_value := round(v_enc.value * case when v_perfect
                     then coalesce(game.config_numeric('fishing_perfect_bonus'), 1.25)
                     else 1 end, 2);

  update public.fishing_encounters
     set status = 'landed', resolved_at = now(), score = v_score
   where id = v_enc.id;

  insert into public.fishery_hold
    (user_id, species_code, weight_kg, value, was_active, trip_id, encounter_id)
  values (v_user, v_enc.species_code, v_enc.weight_kg, v_value, true, v_trip.id, v_enc.id);

  insert into public.user_fish_log (user_id, species_code, catches, best_kg)
  values (v_user, v_enc.species_code, 1, v_enc.weight_kg)
  on conflict (user_id, species_code) do update
    set catches = public.user_fish_log.catches + 1,
        best_kg = greatest(public.user_fish_log.best_kg, excluded.best_kg),
        best_at = case when excluded.best_kg > public.user_fish_log.best_kg
                       then now() else public.user_fish_log.best_at end;

  update public.fishing_trips
     set landed = landed + 1,
         streak = streak + 1,
         best_streak = greatest(best_streak, streak + 1)
   where id = v_trip.id;

  if v_fish.rarity = 'legendary' then
    perform game.grant_crate(v_user, 'legendary', 'fishing_legendary');
  elsif v_fish.rarity = 'epic' then
    perform game.grant_crate(v_user, 'rare', 'fishing_epic');
  end if;

  return jsonb_build_object(
    'status', 'landed',
    'species', v_fish.code, 'name', v_fish.name, 'rarity', v_fish.rarity,
    'blurb', v_fish.blurb,
    'weight_kg', v_enc.weight_kg, 'value', v_value,
    'perfect', v_perfect, 'score', v_score,
    'streak', v_trip.streak + 1,
    'haul_bonus', least(
      least(1 + coalesce(game.config_numeric('fishing_haul_step'), 0.12)
              * greatest(v_trip.best_streak, v_trip.streak + 1),
            coalesce(game.config_numeric('fishing_haul_cap'), 2.0)),
      (select haul_cap from public.fishing_spots where code = v_trip.spot_code)),
    'is_personal_best', (select l.best_kg <= v_enc.weight_kg
                           from public.user_fish_log l
                          where l.user_id = v_user
                            and l.species_code = v_enc.species_code));
end $$;

-- ----------------------------------------------------------------------------
-- 13. Supplies
-- ----------------------------------------------------------------------------
create or replace function public.buy_fishing_supply(p_code text, p_qty int default 1)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user  uuid := auth.uid();
  v_item  public.fishing_supplies%rowtype;
  v_cash  numeric;
  v_cost  numeric;
  v_qty   int := greatest(coalesce(p_qty, 1), 1);
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_item from public.fishing_supplies where code = p_code;
  if not found then raise exception 'unknown supply'; end if;

  perform game.ensure_fishery(v_user);
  v_cost := v_item.price * v_qty;

  select cash_balance into v_cash from public.profiles where id = v_user for update;
  if v_cash < v_cost then
    return jsonb_build_object('status', 'rejected', 'reason', 'insufficient cash');
  end if;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'fishing_supply', -v_cost, 'fishing_supply', v_item.code);

  insert into public.user_fishing_supplies (user_id, code, qty)
  values (v_user, v_item.code, v_qty)
  on conflict (user_id, code) do update
    set qty = public.user_fishing_supplies.qty + excluded.qty;

  return jsonb_build_object('status', 'bought', 'code', v_item.code,
                            'name', v_item.name, 'qty', v_qty, 'cost', v_cost);
end $$;

-- Supplies are loaded onto the boat during a trip, which is what makes them a
-- decision: you commit them before you know what is down there.
create or replace function public.use_fishing_supply(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_item public.fishing_supplies%rowtype;
  v_trip public.fishing_trips%rowtype;
  v_have int;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_item from public.fishing_supplies where code = p_code;
  if not found then raise exception 'unknown supply'; end if;

  select * into v_trip from public.fishing_trips
   where user_id = v_user and status = 'active' for update;
  if v_trip.id is null then
    return jsonb_build_object('status', 'rejected', 'reason', 'you are not on a trip');
  end if;

  select qty into v_have from public.user_fishing_supplies
   where user_id = v_user and code = p_code for update;
  if coalesce(v_have, 0) < 1 then
    return jsonb_build_object('status', 'rejected', 'reason', format('no %s aboard', v_item.name));
  end if;

  update public.user_fishing_supplies set qty = qty - 1
   where user_id = v_user and code = p_code;

  update public.fishing_trips
     set chum_casts  = chum_casts
                       + case when p_code = 'chum' then v_item.uses else 0 end,
         bait_casts  = bait_casts
                       + case when p_code = 'live_bait' then v_item.uses else 0 end,
         spare_lines = spare_lines
                       + case when p_code = 'spare_line' then v_item.uses else 0 end
   where id = v_trip.id;

  return jsonb_build_object('status', 'used', 'code', p_code, 'name', v_item.name,
                            'uses', v_item.uses);
end $$;

-- ----------------------------------------------------------------------------
-- 14. Gear, now licence-gated.
--     Redefined from 20260722000027_fishing.sql — the only change is the
--     req_* check block.
-- ----------------------------------------------------------------------------
create or replace function public.buy_fishing_gear(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user    uuid := auth.uid();
  v_gear    public.fishing_gear%rowtype;
  v_current public.fishing_gear%rowtype;
  v_row     public.user_fishery%rowtype;
  v_cash    numeric;
  v_lic     record;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  select * into v_gear from public.fishing_gear where code = p_code;
  if not found then raise exception 'unknown gear'; end if;

  perform game.ensure_fishery(v_user);
  select * into v_row from public.user_fishery where user_id = v_user for update;
  select * into v_current from public.fishing_gear
   where code = case v_gear.kind when 'boat' then v_row.boat_code
                                 else v_row.rod_code end;

  if v_current.tier >= v_gear.tier then
    return jsonb_build_object('status', 'rejected',
      'reason', format('you already have %s', v_current.name));
  end if;
  if v_current.tier + 1 <> v_gear.tier then
    return jsonb_build_object('status', 'rejected',
      'reason', 'upgrade one tier at a time');
  end if;

  -- The licence. Money does not open this gate; the catch log does.
  select * into v_lic from game.fishing_licence(v_user);
  if v_gear.req_species_logged > 0 and v_lic.species_logged < v_gear.req_species_logged then
    return jsonb_build_object('status', 'rejected',
      'reason', format('licence: log %s species first (you have %s)',
                       v_gear.req_species_logged, v_lic.species_logged));
  end if;
  if v_gear.req_legendary and not coalesce(v_lic.has_legendary, false) then
    return jsonb_build_object('status', 'rejected',
      'reason', 'licence: land a legendary fish first');
  end if;
  if v_gear.req_best_kg > 0 and coalesce(v_lic.best_kg, 0) < v_gear.req_best_kg then
    return jsonb_build_object('status', 'rejected',
      'reason', format('licence: land a %skg fish first (best so far %skg)',
                       round(v_gear.req_best_kg), round(coalesce(v_lic.best_kg, 0))));
  end if;

  select cash_balance into v_cash from public.profiles where id = v_user for update;
  if v_cash < v_gear.price then
    return jsonb_build_object('status', 'rejected', 'reason', 'insufficient cash');
  end if;

  if v_gear.price > 0 then
    insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
    values (v_user, 'fishing_gear', -v_gear.price, 'fishing_gear', v_gear.code);
  end if;

  update public.user_fishery
     set boat_code = case when v_gear.kind = 'boat' then v_gear.code else boat_code end,
         rod_code  = case when v_gear.kind = 'rod'  then v_gear.code else rod_code  end,
         gear_value = gear_value + v_gear.price,
         updated_at = now()
   where user_id = v_user;

  return jsonb_build_object('status', 'bought', 'code', v_gear.code,
                            'name', v_gear.name, 'kind', v_gear.kind,
                            'price', v_gear.price);
end $$;

-- ----------------------------------------------------------------------------
-- 15. One round trip for the whole screen, now including the trip, the open
--     encounter (so a refresh mid-fight resumes it) and the licence progress.
-- ----------------------------------------------------------------------------
create or replace function public.get_my_fishery()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_row  public.user_fishery%rowtype;
  v_boat public.fishing_gear%rowtype;
  v_rod  public.fishing_gear%rowtype;
  v_trip public.fishing_trips%rowtype;
  v_spot public.fishing_spots%rowtype;
  v_enc  public.fishing_encounters%rowtype;
  v_lic  record;
  v_step numeric := coalesce(game.config_numeric('fishing_haul_step'), 0.12);
  v_cap  numeric := coalesce(game.config_numeric('fishing_haul_cap'), 2.0);
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  perform game.ensure_fishery(v_user);
  perform game.expire_fishing(v_user);
  perform game.accrue_fishing(v_user);
  perform game.refresh_bait(v_user);

  select * into v_row  from public.user_fishery where user_id = v_user;
  select * into v_boat from public.fishing_gear where code = v_row.boat_code;
  select * into v_rod  from public.fishing_gear where code = v_row.rod_code;
  select * into v_lic  from game.fishing_licence(v_user);
  select * into v_trip from public.fishing_trips
   where user_id = v_user and status = 'active';
  if v_trip.id is not null then
    select * into v_spot from public.fishing_spots where code = v_trip.spot_code;
    select * into v_enc  from public.fishing_encounters
     where user_id = v_user and status = 'hooked';
  end if;

  return jsonb_build_object(
    'boat_code', v_boat.code, 'boat_name', v_boat.name, 'boat_tier', v_boat.tier,
    'rod_code', v_rod.code, 'rod_name', v_rod.name, 'rod_tier', v_rod.tier,
    'catch_per_hour', v_boat.catch_per_hour,
    'hold_capacity', v_boat.hold_capacity,
    'bait', v_row.bait,
    'bait_cap', game.config_numeric('fishing_bait_cap')::int,
    'bait_seconds', game.config_numeric('fishing_bait_seconds')::int,
    'next_bait_at', case
      when v_row.bait >= game.config_numeric('fishing_bait_cap')::int then null
      else v_row.bait_updated_at
           + make_interval(secs => game.config_numeric('fishing_bait_seconds')) end,
    'lifetime_catches', v_row.lifetime_catches,
    'lifetime_value', v_row.lifetime_value,
    'gear_value', v_row.gear_value,
    'trips_completed', v_row.trips_completed,
    'best_haul', v_row.best_haul,
    'last_spot_code', v_row.last_spot_code,
    -- Hold count excludes the live well: a well fish is not yours to sell yet.
    'hold_count', (select count(*) from public.fishery_hold
                    where user_id = v_user and trip_id is null),
    'hold_value', (select coalesce(sum(value), 0) from public.fishery_hold
                    where user_id = v_user and trip_id is null),
    'stowed_count', (select count(*) from public.fishery_hold where user_id = v_user),
    'licence', jsonb_build_object(
      'species_logged', coalesce(v_lic.species_logged, 0),
      'has_legendary', coalesce(v_lic.has_legendary, false),
      'best_kg', coalesce(v_lic.best_kg, 0)),
    'supplies', coalesce((select jsonb_object_agg(code, qty)
                            from public.user_fishing_supplies
                           where user_id = v_user and qty > 0), '{}'::jsonb),
    'trip', case when v_trip.id is null then null else jsonb_build_object(
      'id', v_trip.id,
      'spot_code', v_trip.spot_code, 'spot_name', v_spot.name,
      'casts_used', v_trip.casts_used, 'trip_casts', v_spot.trip_casts,
      'landed', v_trip.landed, 'lost', v_trip.lost,
      'streak', v_trip.streak, 'best_streak', v_trip.best_streak,
      'chum_casts', v_trip.chum_casts, 'bait_casts', v_trip.bait_casts,
      'spare_lines', v_trip.spare_lines,
      'haul_bonus', least(least(1 + v_step * v_trip.best_streak, v_cap), v_spot.haul_cap),
      'well_count', (select count(*) from public.fishery_hold where trip_id = v_trip.id),
      'well_value', (select coalesce(sum(value), 0) from public.fishery_hold
                      where trip_id = v_trip.id),
      'started_at', v_trip.started_at) end,
    'encounter', case when v_enc.id is null then null else jsonb_build_object(
      'encounter_id', v_enc.id, 'fight', v_enc.fight,
      'expires_at', v_enc.expires_at, 'hooked_at', v_enc.hooked_at) end);
end $$;

grant execute on function public.start_trip(text) to authenticated;
grant execute on function public.bank_haul() to authenticated;
grant execute on function public.resolve_encounter(uuid, boolean, numeric) to authenticated;
grant execute on function public.buy_fishing_supply(text, int) to authenticated;
grant execute on function public.use_fishing_supply(text) to authenticated;

-- ----------------------------------------------------------------------------
-- 16. Selling must not empty the live well.
--     Redefined from 20260722000027_fishing.sql — the only change is that every
--     read and the delete are now scoped to `trip_id is null`. Without this,
--     hitting Sell mid-trip would cash out fish you had not banked yet and
--     silently skip the haul bonus you were fishing for.
-- ----------------------------------------------------------------------------
create or replace function public.sell_catch()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user  uuid := auth.uid();
  v_total numeric;
  v_count int;
  v_best  record;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  perform game.ensure_fishery(v_user);
  perform game.accrue_fishing(v_user);

  select coalesce(sum(value), 0), count(*) into v_total, v_count
    from public.fishery_hold where user_id = v_user and trip_id is null;

  if v_count = 0 then
    return jsonb_build_object('status', 'empty', 'total', 0, 'count', 0);
  end if;

  select h.value, h.weight_kg, s.name into v_best
    from public.fishery_hold h
    join public.fish_species s on s.code = h.species_code
   where h.user_id = v_user and h.trip_id is null
   order by h.value desc limit 1;

  insert into public.transactions (user_id, type, cash_delta, ref_type)
  values (v_user, 'fishing_sale', v_total, 'fishery');

  delete from public.fishery_hold where user_id = v_user and trip_id is null;

  update public.user_fishery
     set lifetime_catches = lifetime_catches + v_count,
         lifetime_value = lifetime_value + v_total,
         updated_at = now()
   where user_id = v_user;

  return jsonb_build_object('status', 'sold', 'total', v_total, 'count', v_count,
                            'best_name', v_best.name, 'best_value', v_best.value,
                            'best_kg', v_best.weight_kg);
end $$;
