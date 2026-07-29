-- The fight becomes a reading contest.
--
-- The old profile described a duty cycle: strength, relax rate, a tension band
-- to sit inside. That model could not express the difference between a marlin
-- and a halibut, because it only ever had one right answer. The new one
-- describes a repertoire and a reaction budget.
--
-- Both are emitted side by side for now. A client that has not been updated
-- keeps reading the old keys and plays exactly the fight it played before;
-- there is no flag day.
--
-- THE DIFFICULTY DIAL IS `read_ms` — how long the player has to recognise what
-- the fish just did and answer it. That, and nothing else, is what the rod
-- ladder buys. This replaces the old derivation, where difficulty lived in a
-- reel_rate sized against a theoretical-perfect duty cycle; a reading contest
-- has no duty cycle to size against, and pretending otherwise would have left
-- two balance models fighting each other.

alter table public.fish_species
  add column if not exists fight_style text not null default 'scrapper'
    check (fight_style in ('runner','jumper','sounder','scrapper'));

comment on column public.fish_species.fight_style is
  'How it fights. Sent instead of the name, so the fish stays a shadow — but a
   shadow that behaves like something you can learn to recognise.';

-- Runners simply go, a long way, and you hang on.
update public.fish_species set fight_style = 'runner'
 where code in ('tuna','greatwhite','swordfish');
-- Jumpers come out of the water and try to throw the hook in mid-air.
update public.fish_species set fight_style = 'jumper'
 where code in ('marlin','salmon');
-- Sounders are dead weight heading for the bottom.
update public.fish_species set fight_style = 'sounder'
 where code in ('halibut','squid','coelacanth');
-- Everything else is scrappy and close-in. Not weak — busy.
update public.fish_species set fight_style = 'scrapper'
 where code in ('sardine','herring','mackerel','cod','seabass','snapper','koi');

-- ---------------------------------------------------------------------------
-- game.roll_encounter — same schema, signature, volatility and search_path.
-- ---------------------------------------------------------------------------

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
  v_rel    numeric;
  v_diff   numeric;
  v_rodt   int;
  v_out    public.fishing_encounters%rowtype;
  v_fight  jsonb;
  v_stam   int;
  v_str    numeric;
  v_relax  numeric;
  v_duty   numeric;
  v_chall  numeric;
  v_runs   int;
  v_rundur numeric;
  v_slip   numeric := 0.06;
  v_snags  int;
  v_snagms numeric;
  v_dives  int;
  v_divems numeric;
  v_pull   numeric := 0.10;
  v_moves  int;
  v_read   numeric;
  v_grace  int;
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

  v_u := random();
  if v_trip.bait_casts > 0 then v_u := greatest(v_u, random()); end if;
  v_weight := round((v_fish.min_weight_kg
              + v_u * (v_fish.max_weight_kg - v_fish.min_weight_kg))::numeric, 2);
  v_value  := round((v_weight * v_fish.value_per_kg * v_scale)::numeric, 2);

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
  v_rundur := least(1400, greatest(600, v_stam * 0.10)) * v_spot.run_mult;
  v_snags  := case when v_stam >= 9000 then v_spot.snags else 0 end;
  v_dives  := case when v_stam >= 9000 then v_spot.dives else 0 end;
  v_snagms := least(1600, greatest(700, v_stam * 0.11));
  v_divems := least(2600, greatest(900, v_stam * 0.16));

  v_str   := greatest(0.20, 0.35 + 0.55 * v_diff - 0.04 * (v_rodt - 1));
  v_relax := (0.45 + 0.10 * (v_rodt - 1)) * v_spot.drag_mult;
  v_duty  := v_relax / (v_str + v_relax);
  v_chall := least(0.92, greatest(0.42,
               0.50 + 0.35 * v_diff - 0.05 * (v_rodt - 1)));

  -- How many times it throws something at you. A bigger animal has more in it.
  v_moves := (3 + floor(v_diff * 5))::int;

  -- The reaction budget. A rod tier is worth ~190ms, and a harder fish shortens
  -- what any rod gives you. A hand line on a big fish lands near the floor
  -- (~350ms, genuinely hard); the Abyssal Rod on a small one hits the ceiling
  -- and is close to a formality — which is exactly the curve a ladder should
  -- have, and exactly what the old model failed to deliver.
  v_read := least(1600, greatest(320,
              (420 + 190 * (v_rodt - 1)) * (1.25 - 0.45 * v_diff)));

  -- Mistakes you survive. The first rod gives one; the best gives three.
  v_grace := 1 + floor((v_rodt - 1) / 2.0)::int;

  v_fight := jsonb_build_object(
    -- ---- the reading contest ------------------------------------------------
    'style',            v_fish.fight_style,
    'moves',            v_moves,
    'read_ms',          round(v_read)::int,
    'tell_ms',          500,
    'hold_ms',          700,
    -- Landing it takes moves-1 correct reads, so one may be dropped without
    -- the fight becoming unwinnable, only longer.
    'stamina_per_read', round((1.0 / greatest(1, v_moves - 1))::numeric, 4),
    'loss_on_miss',     0.08,
    'gain_per_pump',    0.025,
    'grace_misses',     v_grace,

    -- ---- the old duty-cycle fight, still emitted ---------------------------
    -- An un-updated client reads only these and plays what it always played.
    'bite_ms',        round(600 + random() * 3400)::int,
    'hook_window_ms', greatest(320, round(900 - 350 * v_diff + 90 * (v_rodt - 1))::int),
    'stamina_ms',     v_stam,
    'strength',       round(v_str, 3),
    'relax_rate',     round(v_relax, 3),
    'reel_rate',      round(((1 + v_runs * (v_rundur / 1000.0) * v_slip
                                + v_dives * (v_divems / 1000.0) * v_pull)
                             / (greatest(1.0, (v_stam - v_runs * v_rundur) / 1000.0)
                                * v_duty * v_chall))::numeric, 4),
    'challenge',      round(v_chall, 3),
    'slip_rate',      v_slip,
    'run_ms',         round(v_rundur)::int,
    'band_low',       round(greatest(0.18, 0.35 - 0.03 * (v_rodt - 1))::numeric, 3),
    'band_high',      0.70,
    'over_mult',      1.6,
    'surge_rate',     round((0.75 * v_str + 0.55 * v_relax)::numeric, 3),
    'runs',           v_runs,
    'snags',          v_snags,
    'snag_ms',        round(v_snagms)::int,
    'dives',          v_dives,
    'dive_ms',        round(v_divems)::int,
    'dive_pull',      v_pull,
    'band_decay',     v_spot.band_decay,
    'shadow',         case when v_weight >= 60 then 'huge'
                           when v_weight >= 8  then 'big' else 'small' end,
    'difficulty',     round(v_diff, 3));

  insert into public.fishing_encounters
    (trip_id, user_id, species_code, weight_kg, value, fight, min_fight_ms, expires_at)
  values (p_trip, v_trip.user_id, v_fish.code, v_weight, v_value, v_fight,
          (v_fight ->> 'bite_ms')::int + 900,
          now() + make_interval(
            secs => coalesce(game.config_numeric('fishing_encounter_seconds'), 90)))
  returning * into v_out;

  return v_out;
end $$;
