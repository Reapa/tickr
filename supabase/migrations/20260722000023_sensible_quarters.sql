-- ============================================================================
-- Migration 43: Sensible news — earnings quarters that actually progress.
--
-- Bugs (a keen-eyed player spots these instantly):
--   * Every quarter was picked at RANDOM ('Q' || floor(random()*4)), so a
--     company could "report Q2 estimates" then "report Q1" then "Q1" again,
--     jumping around and repeating the SAME quarter within a day.
--
-- Fix — model earnings properly, per company:
--   * Each asset carries an advancing earnings counter; every report steps it
--     Q1 → Q2 → Q3 → Q4 → Q1. A company never repeats or goes backwards.
--   * A cooldown (~one game-quarter) stops a company reporting earnings again
--     for a while, so you don't see the same firm report twice in a day.
--   * Counters are seeded randomly so companies are staggered across quarters,
--     the way a real earnings calendar is spread out.
-- General analyst flavour in other news ("waiting on Q2 data") uses a game-time
-- quarter, which is consistent for all news at a given moment.
-- ============================================================================

-- Game-time quarter for general news flavour: consistent + monotonic per year.
create or replace function game.current_quarter()
returns text
language sql
stable
as $$
  select 'Q' || (1 + floor(
      mod(extract(epoch from now())::numeric,
          game.config_numeric('seconds_per_game_year'))
      / (game.config_numeric('seconds_per_game_year') / 4)
    )::int)::text;
$$;

-- Map a per-company earnings counter to a quarter label (wraps Q4 → Q1).
create or replace function game.quarter_label(p_seq int)
returns text
language sql
immutable
as $$
  select 'Q' || (1 + (p_seq % 4))::text;
$$;

-- Per-company earnings state (hidden — NOT in the assets grant).
alter table public.assets
  add column earnings_seq    int,
  add column last_earnings_at timestamptz;
-- Stagger existing companies across the calendar so they don't all report Q1.
update public.assets set earnings_seq = floor(random() * 4)::int;

-- Coherence: some news only makes sense for the right asset. A "raises its
-- dividend" story must not fire on a growth stock that pays no dividend.
alter table public.event_templates
  add column requires_income boolean not null default false;
update public.event_templates set requires_income = true where code = 'dividend_hike';

-- ---------------------------------------------------------------------------
-- spawn_market_event: general news. {quarter} flavour now game.current_quarter().
-- (Unchanged from migration 20260722000010 except the 'quarter' var.)
-- ---------------------------------------------------------------------------
create or replace function game.spawn_market_event()
returns void
language plpgsql
as $$
declare
  v_tpl       public.event_templates%rowtype;
  v_asset     public.assets%rowtype;
  v_sector    text;
  v_impact    numeric;
  v_sentiment text;
  v_major     boolean := random() < game.config_numeric('major_event_share');
  v_headline  text;
  v_body      text;
  v_detail    text;
  v_vars      jsonb;
  v_firms     text[] := array['Morgan Sterling', 'Blackvale Capital', 'Goldwater',
                              'Meridian Research', 'Cormorant & Co', 'Northbridge',
                              'Pinnacle Securities', 'Hastings Partners'];
  v_pos text[] := array[
    'Buyers piled in as {firm} lifted its {quarter} target.',
    'The roughly {pct} move drew momentum desks through the session.',
    'Bulls pegged the news at around {amount} in added value.',
    '{firm} called it the start of a longer re-rating.',
    'Call buying picked up sharply into the close.'];
  v_neg text[] := array[
    'Sellers hit the exits as {firm} trimmed its {quarter} outlook.',
    'The roughly {pct} slide rattled positioning into the close.',
    'Risk desks flagged as much as {amount} in exposure under review.',
    '{firm} warned the damage could linger past {quarter}.',
    'Put volume jumped as traders hedged the drop.'];
  v_neu text[] := array[
    'Analysts at {firm} said the {quarter} picture is still unclear.',
    'The move faded to about {pct} as desks kept positioning light.',
    '{firm} left its {amount} valuation range unchanged.',
    'Traders shrugged, waiting on {quarter} data.'];
begin
  select t.* into v_tpl
    from public.event_templates t
   where t.is_major = v_major
   order by -ln(1 - random()) / t.weight
   limit 1;
  if not found then return; end if;

  v_impact := round(
    (v_tpl.fv_impact_min + random() * (v_tpl.fv_impact_max - v_tpl.fv_impact_min))::numeric, 4);

  if v_tpl.scope = 'asset' then
    select a.* into v_asset from public.assets a
     where a.is_active and (v_tpl.class_id is null or a.class_id = v_tpl.class_id)
       and game.is_market_open(a.market_hours)
       and (not v_tpl.requires_income or a.income_yield > 0)
     order by random() limit 1;
    if not found then return; end if;
    v_sector := v_asset.sector;
  elsif v_tpl.scope = 'sector' then
    select a.sector into v_sector from public.assets a
     where a.is_active and (v_tpl.class_id is null or a.class_id = v_tpl.class_id)
       and game.is_market_open(a.market_hours)
       and (not v_tpl.requires_income or a.income_yield > 0)
     order by random() limit 1;
    if not found then return; end if;
  end if;

  v_sentiment := case when v_impact > 0.001 then 'positive'
                      when v_impact < -0.001 then 'negative'
                      else 'neutral' end;

  v_vars := jsonb_build_object(
    'name',    coalesce(v_asset.name, ''),
    'symbol',  coalesce(v_asset.symbol, ''),
    'sector',  coalesce(initcap(replace(v_sector, '_', ' ')), ''),
    'pct',     to_char(greatest(round((abs(v_impact) * 100 * (0.7 + random() * 0.7))::numeric, 1), 0.1), 'FM990.0') || '%',
    'firm',    v_firms[1 + floor(random() * array_length(v_firms, 1))::int],
    'quarter', game.current_quarter(),
    'amount',  '$' || (10 + floor(random() * 90))::int
                    || (case when random() < 0.5 then ' million' else ' billion' end));

  v_detail := case v_sentiment
    when 'positive' then v_pos[1 + floor(random() * array_length(v_pos, 1))::int]
    when 'negative' then v_neg[1 + floor(random() * array_length(v_neg, 1))::int]
    else v_neu[1 + floor(random() * array_length(v_neu, 1))::int]
  end;

  v_headline := game.render_template(v_tpl.headline_template, v_vars);
  v_body     := game.render_template(v_tpl.body_template || ' ' || v_detail, v_vars);

  insert into public.market_events
    (template_code, scope, asset_id, sector, headline, body, sentiment,
     fv_impact, vol_multiplier, starts_at, ends_at, is_major)
  values
    (v_tpl.code, v_tpl.scope, v_asset.id, v_sector, v_headline, v_body, v_sentiment,
     v_impact, v_tpl.vol_multiplier,
     now(), now() + make_interval(secs => v_tpl.duration_seconds), v_major);
end;
$$;

-- ---------------------------------------------------------------------------
-- schedule_earnings_event: per-company advancing quarter + a cooldown so a firm
-- reports at most about once per game-quarter (no same-day repeats).
-- (Based on migration 20260722000017; selection + quarter logic changed.)
-- ---------------------------------------------------------------------------
create or replace function game.schedule_earnings_event()
returns void
language plpgsql
as $$
declare
  v_asset     public.assets%rowtype;
  v_roll      numeric := random();
  v_sentiment text;
  v_impact    numeric;
  v_seq       int;
  v_quarter   text;
  v_lead      int;
  v_cooldown  numeric := game.config_numeric('seconds_per_game_year') / 4;  -- one game-quarter
begin
  if (select count(*) from public.scheduled_events where status = 'scheduled')
       >= game.config_numeric('earnings_max_pending')::int then
    return;
  end if;

  -- Sometimes it's a rumour instead of an earnings announcement.
  if random() < game.config_numeric('rumour_share') then
    perform game.schedule_rumour_event();
    return;
  end if;

  -- A company that has no pending report AND hasn't reported within a quarter.
  select a.* into v_asset from public.assets a
   where a.is_active and a.class_id in ('stocks', 'companies')
     and game.is_market_open(a.market_hours)
     and not exists (select 1 from public.scheduled_events se
                      where se.asset_id = a.id and se.status = 'scheduled')
     and (a.last_earnings_at is null
          or a.last_earnings_at < now() - make_interval(secs => v_cooldown::int))
   order by random() limit 1;
  if not found then return; end if;

  -- Step this company's quarter forward and stamp the report time.
  update public.assets
     set earnings_seq = coalesce(earnings_seq, 0) + 1,
         last_earnings_at = now()
   where id = v_asset.id
   returning earnings_seq into v_seq;
  v_quarter := game.quarter_label(v_seq);

  if v_roll < 0.45 then
    v_sentiment := 'positive';
    v_impact := round((0.03 + random() * 0.09)::numeric, 4);
  elsif v_roll < 0.85 then
    v_sentiment := 'negative';
    v_impact := round((-0.12 + random() * 0.09)::numeric, 4);
  else
    v_sentiment := 'neutral';
    v_impact := round((-0.015 + random() * 0.03)::numeric, 4);
  end if;

  v_lead := 90 + floor(random() * 210)::int;

  insert into public.scheduled_events
    (asset_id, kind, headline, quarter, resolves_at,
     sentiment, fv_impact, vol_multiplier, duration_seconds)
  values
    (v_asset.id, 'earnings',
     v_asset.name || ' (' || v_asset.symbol || ') reports ' || v_quarter || ' earnings',
     v_quarter, now() + make_interval(secs => v_lead),
     v_sentiment, v_impact, round((1.4 + random() * 0.8)::numeric, 4), 1200);
end;
$$;
