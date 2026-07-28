-- ============================================================================
-- The Fishery — an idle mini-game for when the markets are shut
--
-- Requested: "an idle fisher game that players can go to if they get bored,
-- are waiting for the markets, or just want something else to do."
--
-- The loop, and why each half exists:
--   IDLE   — your boat fishes while you're away and fills a hold that CAPS.
--            The cap is the whole design: an uncapped idler is a spreadsheet,
--            a capped one is a reason to come back. Every boat fills in ~8h,
--            so it pays out roughly twice a day whatever tier you're on.
--   ACTIVE — casting costs bait, which refills on a timer. That's the thing
--            to actually DO while a market is closed, and being time-gated
--            rather than cash-gated means it can't be farmed.
--   SELL   — the hold converts to cash in one go, and the catch log keeps a
--            permanent record of every species and your personal best.
--
-- Economy placement follows the Companies/Property precedent exactly (the
-- owner's "real cash, off the season track" call): gear is CAPITAL — buying a
-- boat moves cash into business_equity, so total net worth is unchanged and
-- the season figure, which tracks trading skill only, is not credited with a
-- fishing empire. Catch sales pay into cash the same way rent and dividends
-- already do.
--
-- Everything that governs payout — catch rates, hold sizes, prices, rarity
-- weights, bait timers — is catalog or config data, tunable live without a
-- migration.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Config
-- ----------------------------------------------------------------------------
insert into public.game_config (key, value, description) values
  ('fishing_enabled',        '1',   'Master switch for the fishery.'),
  ('fishing_bait_cap',       '30',  'Maximum bait a player can bank.'),
  ('fishing_bait_seconds',   '300', 'Seconds to regenerate one bait.'),
  ('fishing_active_rare_bonus','1.5','Rarity-weight multiplier when you cast by hand — '
                                     'active play should feel better than idling.'),
  ('fishing_value_scale',    '1.0', 'Global multiplier on catch value. The single knob '
                                    'for rebalancing the fishery against the economy.')
on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- 2. Ledger types
-- ----------------------------------------------------------------------------
alter table public.transactions drop constraint transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in (
    'starting_grant', 'trade_buy', 'trade_sell', 'class_unlock',
    'mission_reward', 'challenge_reward', 'season_reward',
    'margin_open', 'margin_close', 'daily_reward', 'passive_income',
    'company_invest', 'company_sale', 'property_invest', 'property_sale',
    'fishing_gear', 'fishing_sale'
  ));
alter table public.transactions add constraint transactions_fishing_gear_debits
  check (type <> 'fishing_gear' or (cash_delta < 0 and qty_delta = 0));
alter table public.transactions add constraint transactions_fishing_sale_credits
  check (type <> 'fishing_sale' or (cash_delta > 0 and qty_delta = 0));

-- ----------------------------------------------------------------------------
-- 3. Species catalog
--
-- value_per_kg x mean weight is the expected value of one catch of that
-- species; combined with `rarity_weight` (an exponential-race weight, same
-- sampling the news engine uses) it sets the whole economy. Tuned so a catch
-- averages ~$10 with everything unlocked. min_boat_tier is what makes an
-- upgrade feel like more than a bigger number: deeper water, better fish.
-- ----------------------------------------------------------------------------
create table public.fish_species (
  code          text primary key,
  name          text not null,
  rarity        text not null check (rarity in ('common','uncommon','rare','epic','legendary')),
  rarity_weight numeric not null check (rarity_weight > 0),
  value_per_kg  numeric(12,2) not null check (value_per_kg > 0),
  min_weight_kg numeric(10,2) not null check (min_weight_kg > 0),
  max_weight_kg numeric(10,2) not null,
  min_boat_tier int not null default 1,
  blurb         text not null default '',
  sort_order    int not null default 0,
  check (max_weight_kg >= min_weight_kg)
);

insert into public.fish_species
  (code, name, rarity, rarity_weight, value_per_kg, min_weight_kg, max_weight_kg,
   min_boat_tier, blurb, sort_order) values
  ('sardine',   'Sardine',      'common',    100, 3.00,   0.20,   0.50, 1,
   'Comes in shoals. Leaves in tins.', 1),
  ('herring',   'Herring',      'common',     90, 3.50,   0.30,   0.80, 1,
   'The fish that funded empires.', 2),
  ('mackerel',  'Mackerel',     'common',     85, 4.00,   0.40,   1.20, 1,
   'Fast, oily, and faintly smug.', 3),
  ('cod',       'Cod',          'common',     70, 6.00,   1.00,   4.00, 1,
   'A whole economy in one fish.', 4),
  ('seabass',   'Sea Bass',     'uncommon',   30, 4.00,   1.00,   3.00, 2,
   'Restaurant money. Knows it.', 5),
  ('snapper',   'Red Snapper',  'uncommon',   26, 4.60,   1.50,   3.50, 2,
   'Bright red and permanently annoyed.', 6),
  ('salmon',    'Salmon',       'uncommon',   22, 5.20,   2.00,   6.00, 2,
   'Swam upstream its whole life for this.', 7),
  ('tuna',      'Bluefin Tuna', 'rare',        8, 1.80,  15.00,  45.00, 3,
   'A torpedo with opinions about your line.', 8),
  ('halibut',   'Halibut',      'rare',        8, 2.00,   8.00,  32.00, 3,
   'A doormat that fights back.', 9),
  ('swordfish', 'Swordfish',    'rare',        7, 1.50,  25.00,  75.00, 3,
   'Armed. Genuinely armed.', 10),
  ('marlin',    'Blue Marlin',  'epic',        2, 2.30,  60.00, 120.00, 4,
   'The one people write books about.', 11),
  ('squid',     'Giant Squid',  'epic',        2, 2.90,  30.00,  90.00, 4,
   'Eight arms, zero manners.', 12),
  ('greatwhite','Great White',  'legendary', 0.4, 3.40, 250.00, 550.00, 5,
   'You did not catch it. You negotiated.', 13),
  ('koi',       'Golden Koi',   'legendary', 0.4, 170.00,  1.00,   3.00, 5,
   'Impossibly far from home, and worth a fortune.', 14),
  ('coelacanth','Coelacanth',   'legendary', 0.4, 43.00,  25.00,  55.00, 5,
   'Extinct for 65 million years. Apparently not.', 15);

-- ----------------------------------------------------------------------------
-- 4. Gear catalog
--
-- Every boat fills its hold in roughly eight hours, so the check-in rhythm is
-- the same at every tier — upgrading buys you a bigger payout per visit and
-- access to deeper water, not a different schedule.
-- ----------------------------------------------------------------------------
create table public.fishing_gear (
  code           text primary key,
  kind           text not null check (kind in ('boat','rod')),
  tier           int not null,
  name           text not null,
  description    text not null,
  price          numeric(18,2) not null check (price >= 0),
  catch_per_hour numeric not null default 0,   -- boats
  hold_capacity  int not null default 0,       -- boats
  rare_bonus     numeric not null default 1,   -- rods: rarity weight multiplier
  sort_order     int not null default 0
);
grant select on public.fish_species, public.fishing_gear to anon, authenticated;

insert into public.fishing_gear
  (code, kind, tier, name, description, price, catch_per_hour, hold_capacity,
   rare_bonus, sort_order) values
  ('boat_row',     'boat', 1, 'Rowboat',
   'It floats, and that is the entire pitch.',            0,    2.0,  12, 1, 1),
  ('boat_skiff',   'boat', 2, 'Coastal Skiff',
   'An outboard motor and reachable reefs.',              2500, 3.3,  20, 1, 2),
  ('boat_trawler', 'boat', 3, 'Trawler',
   'Nets, a winch, and open water. Rare fish start here.',12000, 5.0, 30, 1, 3),
  ('boat_deepsea', 'boat', 4, 'Deep-Sea Cruiser',
   'Goes where the big ones are and stays out overnight.',25000, 7.5, 45, 1, 4),
  ('boat_factory', 'boat', 5, 'Factory Ship',
   'A cannery with a propeller. Nothing is out of reach.',45000, 10.0, 60, 1, 5),
  ('rod_hand',     'rod',  1, 'Hand Line',
   'String. A hook. Optimism.',                           0,      0,   0, 1.0, 11),
  ('rod_carbon',   'rod',  2, 'Carbon Rod',
   'Light, stiff, and far harder to snap.',               1500,   0,   0, 1.4, 12),
  ('rod_pro',      'rod',  3, 'Pro Rig',
   'A reel with a drag system worth more than the boat.', 8000,   0,   0, 2.0, 13),
  ('rod_legend',   'rod',  4, 'Heirloom Rod',
   'Somebody landed something impossible with this.',     30000,  0,   0, 3.0, 14);

-- ----------------------------------------------------------------------------
-- 5. Player state
-- ----------------------------------------------------------------------------
create table public.user_fishery (
  user_id         uuid primary key references public.profiles (id) on delete cascade,
  boat_code       text not null default 'boat_row' references public.fishing_gear (code),
  rod_code        text not null default 'rod_hand' references public.fishing_gear (code),
  bait            int not null default 10 check (bait >= 0),
  bait_updated_at timestamptz not null default now(),
  last_accrued_at timestamptz not null default now(),
  gear_value      numeric(18,2) not null default 0,  -- capital sunk; feeds business_equity
  lifetime_catches int not null default 0,
  lifetime_value  numeric(18,2) not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
alter table public.user_fishery enable row level security;
create policy "own fishery readable" on public.user_fishery
  for select using (user_id = auth.uid());
grant select on public.user_fishery to authenticated;

-- The unsold hold. Capped by the boat, which is what brings players back.
create table public.fishery_hold (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  species_code text not null references public.fish_species (code),
  weight_kg    numeric(10,2) not null,
  value        numeric(18,2) not null,
  was_active   boolean not null default false,  -- cast by hand vs caught idle
  caught_at    timestamptz not null default now()
);
create index fishery_hold_user_idx on public.fishery_hold (user_id);
alter table public.fishery_hold enable row level security;
create policy "own hold readable" on public.fishery_hold
  for select using (user_id = auth.uid());
grant select on public.fishery_hold to authenticated;

-- The permanent record: what you've ever landed, and your personal best.
create table public.user_fish_log (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  species_code text not null references public.fish_species (code),
  catches      int not null default 0,
  best_kg      numeric(10,2) not null default 0,
  first_at     timestamptz not null default now(),
  best_at      timestamptz not null default now(),
  primary key (user_id, species_code)
);
alter table public.user_fish_log enable row level security;
create policy "own fish log readable" on public.user_fish_log
  for select using (user_id = auth.uid());
grant select on public.user_fish_log to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.user_fishery;
    alter publication supabase_realtime add table public.fishery_hold;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 6. Lazy row creation. New players get one on signup; everyone else gets one
--    the first time they open the fishery.
-- ----------------------------------------------------------------------------
create or replace function game.ensure_fishery(p_user uuid)
returns public.user_fishery
language plpgsql
security definer
set search_path = public, game
as $$
declare v_row public.user_fishery%rowtype;
begin
  insert into public.user_fishery (user_id) values (p_user)
  on conflict (user_id) do nothing;
  select * into v_row from public.user_fishery where user_id = p_user;
  return v_row;
end $$;

create or replace function game.fishery_on_new_profile()
returns trigger
language plpgsql
security definer
set search_path = public, game
as $$
begin
  insert into public.user_fishery (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists profiles_fishery_row on public.profiles;
create trigger profiles_fishery_row
  after insert on public.profiles
  for each row execute function game.fishery_on_new_profile();

insert into public.user_fishery (user_id)
select id from public.profiles on conflict (user_id) do nothing;

-- ----------------------------------------------------------------------------
-- 7. Bait regenerates on a timer, materialized whenever we touch it.
-- ----------------------------------------------------------------------------
create or replace function game.refresh_bait(p_user uuid)
returns int
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_cap     int := game.config_numeric('fishing_bait_cap')::int;
  v_seconds numeric := greatest(game.config_numeric('fishing_bait_seconds'), 1);
  v_row     public.user_fishery%rowtype;
  v_gained  int;
begin
  select * into v_row from public.user_fishery where user_id = p_user for update;
  if v_row.user_id is null then return 0; end if;
  if v_row.bait >= v_cap then
    -- Already full: keep the clock at now so a full tank doesn't bank credit.
    update public.user_fishery set bait_updated_at = now() where user_id = p_user;
    return v_row.bait;
  end if;

  v_gained := floor(extract(epoch from now() - v_row.bait_updated_at) / v_seconds)::int;
  if v_gained <= 0 then return v_row.bait; end if;

  update public.user_fishery
     set bait = least(v_cap, v_row.bait + v_gained),
         -- Advance by whole bait only, so the remainder carries to next time.
         bait_updated_at = v_row.bait_updated_at
                           + make_interval(secs => v_gained * v_seconds),
         updated_at = now()
   where user_id = p_user;

  return least(v_cap, v_row.bait + v_gained);
end $$;

-- ----------------------------------------------------------------------------
-- 8. Rolling a catch.
--
-- Weighted by rarity via the exponential race (-ln(1-u)/w), gated by the
-- boat's tier, and tilted toward rare species by the rod (and again by hand
-- casting). Weight within a species is uniform; value is weight x price x the
-- global scale knob.
-- ----------------------------------------------------------------------------
create or replace function game.roll_catch(
  p_user   uuid,
  p_active boolean default false
)
returns public.fishery_hold
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_fish    public.fish_species%rowtype;
  v_boat    public.fishing_gear%rowtype;
  v_rod     public.fishing_gear%rowtype;
  v_row     public.user_fishery%rowtype;
  v_bonus   numeric;
  v_weight  numeric;
  v_value   numeric;
  v_scale   numeric := coalesce(game.config_numeric('fishing_value_scale'), 1);
  v_out     public.fishery_hold%rowtype;
begin
  select * into v_row from public.user_fishery where user_id = p_user;
  if v_row.user_id is null then return v_out; end if;
  select * into v_boat from public.fishing_gear where code = v_row.boat_code;
  select * into v_rod  from public.fishing_gear where code = v_row.rod_code;

  v_bonus := coalesce(v_rod.rare_bonus, 1)
             * case when p_active
                    then coalesce(game.config_numeric('fishing_active_rare_bonus'), 1)
                    else 1 end;

  select s.* into v_fish
    from public.fish_species s
   where s.min_boat_tier <= coalesce(v_boat.tier, 1)
   order by -ln(1 - random())
            / (s.rarity_weight
               * case when s.rarity = 'common' then 1 else v_bonus end)
   limit 1;
  if not found then return v_out; end if;

  v_weight := round((v_fish.min_weight_kg
              + random() * (v_fish.max_weight_kg - v_fish.min_weight_kg))::numeric, 2);
  v_value  := round((v_weight * v_fish.value_per_kg * v_scale)::numeric, 2);

  insert into public.fishery_hold (user_id, species_code, weight_kg, value, was_active)
  values (p_user, v_fish.code, v_weight, v_value, p_active)
  returning * into v_out;

  -- The permanent record, updated at catch time so it survives selling.
  insert into public.user_fish_log (user_id, species_code, catches, best_kg)
  values (p_user, v_fish.code, 1, v_weight)
  on conflict (user_id, species_code) do update
    set catches = public.user_fish_log.catches + 1,
        best_kg = greatest(public.user_fish_log.best_kg, excluded.best_kg),
        best_at = case when excluded.best_kg > public.user_fish_log.best_kg
                       then now() else public.user_fish_log.best_at end;

  -- Landing something extraordinary is worth more than money.
  if v_fish.rarity = 'legendary' then
    perform game.grant_crate(p_user, 'legendary', 'fishing_legendary');
  elsif v_fish.rarity = 'epic' then
    perform game.grant_crate(p_user, 'rare', 'fishing_epic');
  end if;

  return v_out;
end $$;

-- ----------------------------------------------------------------------------
-- 9. Idle accrual. The hold cap is the point — it stops when it's full and
--    waits for you, which is what makes a check-in worth making.
-- ----------------------------------------------------------------------------
create or replace function game.accrue_fishing(p_user uuid default null)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  r        record;
  v_room   int;
  v_due    int;
  i        int;
begin
  if game.config_numeric('fishing_enabled') < 1 then return; end if;

  for r in
    select uf.user_id, uf.last_accrued_at, g.catch_per_hour, g.hold_capacity,
           (select count(*) from public.fishery_hold h where h.user_id = uf.user_id) as held
      from public.user_fishery uf
      join public.fishing_gear g on g.code = uf.boat_code
     where (p_user is null or uf.user_id = p_user)
  loop
    v_room := greatest(r.hold_capacity - r.held, 0);
    v_due  := floor(extract(epoch from now() - r.last_accrued_at) / 3600.0
                    * r.catch_per_hour)::int;
    v_due  := least(v_due, v_room);

    for i in 1 .. greatest(v_due, 0) loop
      perform game.roll_catch(r.user_id, false);
    end loop;

    -- Advance the clock for everyone every run, whether or not they caught
    -- anything: otherwise a player whose hold was full banks hours of credit
    -- and empties it into an instant windfall the moment they sell.
    update public.user_fishery
       set last_accrued_at = now(), updated_at = now()
     where user_id = r.user_id;
  end loop;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('accrue-fishing')
      where exists (select 1 from cron.job where jobname = 'accrue-fishing');
    perform cron.schedule('accrue-fishing', '*/5 * * * *',
      $cron$ select game.accrue_fishing(); $cron$);
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 10. Player actions
-- ----------------------------------------------------------------------------

-- Cast by hand. Costs bait, which is time-gated, so this can never be farmed.
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
  v_held  int;
  v_bait  int;
  v_catch public.fishery_hold%rowtype;
  v_fish  public.fish_species%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if game.config_numeric('fishing_enabled') < 1 then
    return jsonb_build_object('status', 'rejected', 'reason', 'the fishery is closed');
  end if;

  perform game.ensure_fishery(v_user);
  v_bait := game.refresh_bait(v_user);
  select * into v_row from public.user_fishery where user_id = v_user for update;
  select * into v_boat from public.fishing_gear where code = v_row.boat_code;

  if v_row.bait < 1 then
    return jsonb_build_object('status', 'rejected', 'reason', 'out of bait',
                              'bait', v_row.bait);
  end if;

  select count(*) into v_held from public.fishery_hold where user_id = v_user;
  if v_held >= v_boat.hold_capacity then
    return jsonb_build_object('status', 'rejected', 'reason', 'the hold is full',
                              'bait', v_row.bait);
  end if;

  update public.user_fishery
     set bait = bait - 1, updated_at = now()
   where user_id = v_user;

  v_catch := game.roll_catch(v_user, true);
  if v_catch.id is null then
    -- Refund: no fish exists we could have caught, so the bait wasn't used.
    update public.user_fishery set bait = bait + 1 where user_id = v_user;
    return jsonb_build_object('status', 'rejected', 'reason', 'nothing biting');
  end if;

  select * into v_fish from public.fish_species where code = v_catch.species_code;

  return jsonb_build_object(
    'status', 'caught',
    'species', v_fish.code, 'name', v_fish.name, 'rarity', v_fish.rarity,
    'blurb', v_fish.blurb,
    'weight_kg', v_catch.weight_kg, 'value', v_catch.value,
    'bait', v_row.bait - 1,
    'hold', v_held + 1, 'hold_capacity', v_boat.hold_capacity,
    'is_personal_best', (select l.best_kg <= v_catch.weight_kg
                           from public.user_fish_log l
                          where l.user_id = v_user
                            and l.species_code = v_catch.species_code));
end $$;

-- Sell the whole hold. One button, one number — the payoff moment.
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
    from public.fishery_hold where user_id = v_user;

  if v_count = 0 then
    return jsonb_build_object('status', 'empty', 'total', 0, 'count', 0);
  end if;

  select h.value, h.weight_kg, s.name into v_best
    from public.fishery_hold h
    join public.fish_species s on s.code = h.species_code
   where h.user_id = v_user
   order by h.value desc limit 1;

  insert into public.transactions (user_id, type, cash_delta, ref_type)
  values (v_user, 'fishing_sale', v_total, 'fishery');

  delete from public.fishery_hold where user_id = v_user;

  update public.user_fishery
     set lifetime_catches = lifetime_catches + v_count,
         lifetime_value = lifetime_value + v_total,
         updated_at = now()
   where user_id = v_user;

  return jsonb_build_object('status', 'sold', 'total', v_total, 'count', v_count,
                            'best_name', v_best.name, 'best_value', v_best.value,
                            'best_kg', v_best.weight_kg);
end $$;

-- Buy gear. Capital, not consumption: the spend moves into business_equity, so
-- total net worth is unchanged (it does reduce the season figure, exactly like
-- committing capital to a company or a property).
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

-- One round trip for the whole screen: state, bait, hold and capacity.
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
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  perform game.ensure_fishery(v_user);
  perform game.accrue_fishing(v_user);
  perform game.refresh_bait(v_user);

  select * into v_row  from public.user_fishery where user_id = v_user;
  select * into v_boat from public.fishing_gear where code = v_row.boat_code;
  select * into v_rod  from public.fishing_gear where code = v_row.rod_code;

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
    'hold_count', (select count(*) from public.fishery_hold where user_id = v_user),
    'hold_value', (select coalesce(sum(value), 0) from public.fishery_hold
                    where user_id = v_user));
end $$;

grant execute on function public.cast_line() to authenticated;
grant execute on function public.sell_catch() to authenticated;
grant execute on function public.buy_fishing_gear(text) to authenticated;
grant execute on function public.get_my_fishery() to authenticated;

-- ----------------------------------------------------------------------------
-- 11. Net worth: gear is capital on the business track.
--     Redefined from 20260722000025_market_depth.sql — the ONLY change is the
--     business term, which now also sums user_fishery.gear_value.
-- ----------------------------------------------------------------------------
create or replace function game.market_tick()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_tick_seconds numeric := game.config_numeric('tick_seconds');
  v_year_seconds numeric := game.config_numeric('seconds_per_game_year');
  v_halflife     numeric := game.config_numeric('flow_halflife_seconds');
  v_spawn_prob   numeric := game.config_numeric('event_spawn_probability');
  v_retention    numeric := game.config_numeric('price_tick_retention_days');
  v_flow_cap     numeric := game.config_numeric('flow_cap_multiple');
  v_dt           numeric;
  v_decay        numeric;
begin
  if not pg_try_advisory_xact_lock(hashtext('game.market_tick')) then
    return;
  end if;

  v_dt    := v_tick_seconds / v_year_seconds;
  v_decay := power(0.5, v_tick_seconds / v_halflife);

  perform game.resolve_scheduled_events();

  if random() < v_spawn_prob then
    perform game.spawn_market_event();
  end if;
  if random() < game.config_numeric('earnings_schedule_probability') then
    perform game.schedule_earnings_event();
  end if;

  with pending as (
    select id, scope, asset_id, sector, fv_impact
      from public.market_events
     where not applied and starts_at <= now()
     for update
  ),
  shocked as (
    update public.assets a
       set fair_value = greatest(0.01, a.fair_value * (1 + p.fv_impact))
      from pending p
     where a.is_active and game.is_market_open(a.market_hours)
       and (   (p.scope = 'asset'  and a.id = p.asset_id)
            or (p.scope = 'sector' and a.sector = p.sector)
            or  p.scope = 'market')
     returning p.id
  )
  update public.market_events e
     set applied = true
   where e.id in (select id from pending);

  with vol as (
    select a.id as asset_id,
           coalesce(exp(sum(ln(e.vol_multiplier))), 1) as mult
      from public.assets a
      join public.market_events e
        on e.starts_at <= now() and e.ends_at > now() and e.vol_multiplier > 1
       and (   (e.scope = 'asset'  and e.asset_id = a.id)
            or (e.scope = 'sector' and e.sector = a.sector)
            or  e.scope = 'market')
     group by a.id
  ),
  draws as (
    select a.id as asset_id, game.random_normal() as z, game.random_normal() as z2
      from public.assets a
     where a.is_active and game.is_market_open(a.market_hours)
  ),
  adv as (
    select a.id as asset_id, a.class_id, a.current_price, a.reversion_speed,
           a.impact_coef, a.liquidity, a.fair_value as old_fair,
           least(greatest(a.flow * v_decay, -v_flow_cap * a.liquidity),
                 v_flow_cap * a.liquidity) as new_flow,
           a.base_volatility * coalesce(v.mult, 1) as sigma,
           d.z as z,
           greatest(0.0001, coalesce(a.anchor_price, a.fair_value) * exp(
             (a.drift
              + (case a.class_id when 'forex' then 3.0 when 'real_estate' then 0.5
                                 when 'crypto' then 0.3 else 0.4 end)
                * ln(coalesce(a.reference_price, a.fair_value)
                     / greatest(0.0001, coalesce(a.anchor_price, a.fair_value)))
             ) * v_dt
             + (case a.class_id when 'forex' then 0.02 when 'crypto' then 0.25
                                when 'real_estate' then 0.05 else 0.10 end)
               * sqrt(v_dt) * d.z2)) as new_anchor
      from draws d
      join public.assets a on a.id = d.asset_id
      left join vol v on v.asset_id = d.asset_id
  ),
  adv2 as (
    select adv.*,
           greatest(0.01, old_fair * exp(
             (case class_id when 'forex' then 150.0 when 'real_estate' then 100.0
                            when 'crypto' then 100.0 else 250.0 end)
               * ln(new_anchor / greatest(0.01, old_fair)) * v_dt
             + sigma * sqrt(v_dt) * z)) as new_fair
      from adv
  )
  update public.assets a
     set anchor_price = adv2.new_anchor,
         fair_value   = adv2.new_fair,
         flow         = adv2.new_flow,
         current_price = greatest(0.01,
           adv2.current_price + adv2.reversion_speed * (
             adv2.new_fair * (1 + game.flow_impact(adv2.new_flow, adv2.liquidity,
                                                   adv2.impact_coef))
             - adv2.current_price)),
         updated_at = now()
    from adv2
   where a.id = adv2.asset_id;

  perform game.execute_triggered_orders();
  perform game.process_leveraged_positions();

  insert into public.price_ticks (asset_id, price)
  select id, current_price from public.assets
   where is_active and game.is_market_open(market_hours);

  delete from public.price_ticks
   where tick_at < now() - make_interval(days => v_retention::int);

  update public.profiles p
     set trading_net_worth = calc.trading,
         business_equity   = calc.business,
         net_worth         = calc.trading + calc.business
    from (
      select p2.id,
             p2.cash_balance
               + coalesce((select sum(h.quantity * a.current_price)
                             from public.holdings h
                             join public.assets a on a.id = h.asset_id
                            where h.user_id = p2.id), 0)
               + coalesce((select sum(greatest(0, lp.margin +
                             case when lp.side = 'long'
                                  then lp.quantity * (a.current_price * (1 - a.spread / 2)
                                                      - lp.entry_price)
                                  else lp.quantity * (lp.entry_price
                                                      - a.current_price * (1 + a.spread / 2))
                             end))
                             from public.leveraged_positions lp
                             join public.assets a on a.id = lp.asset_id
                            where lp.user_id = p2.id and lp.status = 'open'), 0) as trading,
             coalesce((select sum(case
                             when uc.status = 'public' and uc.public_asset_id is not null
                             then uc.founder_shares * coalesce(pa.current_price, 0)
                             else uc.valuation end)
                         from public.user_companies uc
                         left join public.assets pa on pa.id = uc.public_asset_id
                        where uc.user_id = p2.id and uc.status <> 'sold'), 0)
             + coalesce((select sum(pr.value) from public.user_properties pr
                          where pr.user_id = p2.id and pr.status = 'owned'), 0)
             + coalesce((select uf.gear_value from public.user_fishery uf
                          where uf.user_id = p2.id), 0) as business
        from public.profiles p2
    ) calc
   where calc.id = p.id;

  insert into public.net_worth_history (user_id, net_worth)
  select id, net_worth from public.profiles;

  delete from public.net_worth_history
   where tick_at < now() - make_interval(days => v_retention::int);

  perform game.update_season_scores();
  perform game.resolve_seasons();
  perform game.resolve_challenges();
end;
$$;
