-- Per-spot fight mechanics.
--
-- Until now every spot played identically and differed only in how hard it
-- pulled: `fight_scale` stretched the stamina and that was the whole of it.
-- The catalog's own blurbs promise more than that — the Reef has "plenty to
-- snag a line on", the Canyon "drops away to nothing" — and none of it was
-- real.
--
-- Two new hazards, both scheduled by the server and merely animated by the
-- client, plus a slow line-abrasion term:
--
--   SNAG   the fish makes for structure. While a snag window is open you must
--          keep the line LOADED to turn it; let the line go slack and it
--          reaches the structure and breaks you off. This deliberately
--          inverts the advice for a run, where you must ease off — so the two
--          hazards ask for opposite things and the player has to read which
--          one they are in. Windows are scheduled clear of runs, because
--          overlapping them would be a coin flip rather than a decision.
--
--   DIVE   the fish sounds. Progress bleeds for as long as it lasts and there
--          is nothing to react to except deciding to spend line-safety to
--          stop it. Unlike a run it adds no tension of its own, so the
--          correct play is to wind THROUGH it — again, the opposite of a run.
--
--   BAND DECAY  the safe band's ceiling falls over the course of the fight,
--          which is ice or coral wearing at the leader. Late in a long fight
--          the same tension that was safe at the start is not.
--
-- BALANCE. `reel_rate` in cast_line is derived, not tuned: it is sized so that
-- a fight played at `challenge` of the theoretical-perfect duty cycle just
-- lands. Anything that costs progress therefore HAS to enter that equation or
-- the spot silently gets harder and the payout curve moves with it. Dives cost
-- progress, so they join runs in the numerator. Snags cost no progress at all
-- (they are a risk gate, not a tax) and band decay costs none either, so
-- neither touches it. Dive time is NOT subtracted from the windable seconds
-- the way run time is, because you can and should wind during a dive.

alter table public.fishing_spots
  add column if not exists snags      int     not null default 0
    check (snags >= 0 and snags <= 4),
  add column if not exists dives      int     not null default 0
    check (dives >= 0 and dives <= 4),
  add column if not exists band_decay numeric not null default 0
    check (band_decay >= 0 and band_decay <= 0.25),
  add column if not exists run_mult   numeric not null default 1
    check (run_mult > 0 and run_mult <= 3),
  add column if not exists drag_mult  numeric not null default 1
    check (drag_mult >= 0.5 and drag_mult <= 1.5);

comment on column public.fishing_spots.snags is
  'Structure windows per fight. Slack line during one loses the fish.';
comment on column public.fishing_spots.dives is
  'Sounding runs per fight. Bleed progress; wind through them.';
comment on column public.fishing_spots.band_decay is
  'How far band_high falls across a full fight, as an absolute amount.';
comment on column public.fishing_spots.run_mult is
  'Stretches how long each run lasts. Open water runs long.';
comment on column public.fishing_spots.drag_mult is
  'Scales relax_rate. Below 1 is a stiff drag that bleeds tension slowly.';

-- The Harbour stays deliberately plain: it is the spot that teaches the fight,
-- and adding a hazard there would be teaching two things at once.
update public.fishing_spots set snags = 2                     where code = 'reef';
update public.fishing_spots set run_mult = 1.45               where code = 'open_water';
update public.fishing_spots set dives = 2                     where code = 'canyon';
update public.fishing_spots set dives = 1, snags = 1          where code = 'trench';
update public.fishing_spots set band_decay = 0.10,
                                drag_mult = 0.82              where code = 'polar';

-- ---------------------------------------------------------------------------
-- game.roll_encounter, rebuilt around the new terms. Signature, schema,
-- volatility and search_path are all kept identical to the original — this is
-- an internal function called by public.cast_line(), and quietly moving it or
-- widening its search_path is exactly how a SECURITY DEFINER goes wrong.
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
  v_pull   numeric := 0.10;  -- progress per second lost while sounding
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

  -- Hazards only appear once there is enough fight to fit them in. A four
  -- second cod does not get two snag windows and a sounding run.
  v_snags  := case when v_stam >= 9000 then v_spot.snags else 0 end;
  v_dives  := case when v_stam >= 9000 then v_spot.dives else 0 end;
  v_snagms := least(1600, greatest(700, v_stam * 0.11));
  v_divems := least(2600, greatest(900, v_stam * 0.16));

  v_str   := greatest(0.20, 0.35 + 0.55 * v_diff - 0.04 * (v_rodt - 1));
  v_relax := (0.45 + 0.10 * (v_rodt - 1)) * v_spot.drag_mult;
  v_duty  := v_relax / (v_str + v_relax);

  v_chall := least(0.92, greatest(0.42,
               0.50 + 0.35 * v_diff - 0.05 * (v_rodt - 1)));

  v_fight := jsonb_build_object(
    'bite_ms',        round(600 + random() * 3400)::int,
    'hook_window_ms', greatest(320, round(900 - 350 * v_diff + 90 * (v_rodt - 1))::int),
    'stamina_ms',     v_stam,
    'strength',       round(v_str, 3),
    'relax_rate',     round(v_relax, 3),
    -- Runs cost the line they drag off AND the seconds you cannot wind
    -- through; dives cost only the progress they bleed, because winding is
    -- exactly what you are supposed to do during one. Both have to be in here
    -- or `challenge` quietly means something harsher on a hazardous spot.
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
    -- The new hazards. Zero everywhere they do not apply, so a client that
    -- has never heard of them plays exactly the fight it played before.
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
