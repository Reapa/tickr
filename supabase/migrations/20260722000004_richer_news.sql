-- ============================================================================
-- Migration 23: richer, more unique generated news
--
-- The event generator (migration 8) rendered a fixed body per template with
-- only {name}/{symbol}/{sector} substitution, so the same template always read
-- identically. This adds a small token engine and dynamic "market colour" so
-- each article reads fresh: a randomised move %, an analyst firm, a quarter, a
-- dollar figure, and a sentiment-appropriate detail sentence appended to the
-- body. Also seeds extra templates for headline variety. The tap-through news
-- UI already surfaces the body, so this lands with no client change.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Reset-safety: this migration (and 000010) inserts event_templates whose
-- class_id references asset_classes, but the classes live in seed.sql, which
-- `supabase db reset` only runs AFTER all migrations. Seed the classes here
-- idempotently so a from-scratch reset succeeds. On the hosted DB (already
-- migrated) this never re-runs, so it is a no-op there. Seed.sql now upserts
-- the same rows with `on conflict do nothing`, keeping a single source of truth.
-- ----------------------------------------------------------------------------
insert into public.asset_classes (id, name, description, unlock_cost, is_enabled, sort_order) values
  ('stocks',      'Stocks',      'Shares in fictional companies across five sectors. Free to trade from day one.', 0, true, 1),
  ('real_estate', 'Real Estate', 'Property funds: slower-moving, steadier income-style assets. Buy your way in.', 50000, true, 2),
  ('companies',   'Companies',   'Own entire private companies. Coming soon.', 250000, false, 3),
  ('margin',      'Broker License', 'Trade with leverage: control 5-100x your stake, long or short. High risk, high reward — you can lose your whole margin.', 25000, true, 4),
  ('crypto',      'Crypto',      'The 24/7 casino: wildly volatile coins that never stop trading. Weekends belong to crypto.', 2500, true, 5),
  ('forex',       'Forex',       'Currency pairs: tiny moves, huge liquidity, open 24/5. Where leverage earns its keep.', 10000, true, 6)
on conflict (id) do nothing;

-- ----------------------------------------------------------------------------
-- Tiny mustache-style renderer: replace every {key} with p_vars->>key.
-- ----------------------------------------------------------------------------
create or replace function game.render_template(p_tpl text, p_vars jsonb)
returns text
language plpgsql
immutable
as $$
declare
  k   text;
  v   text;
  out text := p_tpl;
begin
  for k, v in select key, value from jsonb_each_text(p_vars) loop
    out := replace(out, '{' || k || '}', v);
  end loop;
  return out;
end;
$$;

-- ----------------------------------------------------------------------------
-- Spawn: same weighted pick + impact roll as before, but now renders headline
-- and body through the token engine and appends a random detail sentence keyed
-- to sentiment, so repeated templates still read differently.
-- ----------------------------------------------------------------------------
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
   order by -ln(1 - random()) / t.weight
   limit 1;
  if not found then return; end if;

  v_impact := round(
    (v_tpl.fv_impact_min + random() * (v_tpl.fv_impact_max - v_tpl.fv_impact_min))::numeric, 4);

  if v_tpl.scope = 'asset' then
    select a.* into v_asset from public.assets a
     where a.is_active and (v_tpl.class_id is null or a.class_id = v_tpl.class_id)
       and game.is_market_open(a.market_hours)
     order by random() limit 1;
    if not found then return; end if;
    v_sector := v_asset.sector;
  elsif v_tpl.scope = 'sector' then
    select a.sector into v_sector from public.assets a
     where a.is_active and (v_tpl.class_id is null or a.class_id = v_tpl.class_id)
       and game.is_market_open(a.market_hours)
     order by random() limit 1;
    if not found then return; end if;
  end if;

  v_sentiment := case when v_impact > 0.001 then 'positive'
                      when v_impact < -0.001 then 'negative'
                      else 'neutral' end;

  -- Dynamic detail tokens. {pct} is a plausible display move around the (hidden)
  -- fair-value shock; the rest are pure flavour.
  v_vars := jsonb_build_object(
    'name',    coalesce(v_asset.name, ''),
    'symbol',  coalesce(v_asset.symbol, ''),
    'sector',  coalesce(initcap(replace(v_sector, '_', ' ')), ''),
    'pct',     to_char(greatest(round((abs(v_impact) * 100 * (0.7 + random() * 0.7))::numeric, 1), 0.1), 'FM990.0') || '%',
    'firm',    v_firms[1 + floor(random() * array_length(v_firms, 1))::int],
    'quarter', 'Q' || (1 + floor(random() * 4))::int,
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
     fv_impact, vol_multiplier, starts_at, ends_at)
  values
    (v_tpl.code, v_tpl.scope, v_asset.id, v_sector, v_headline, v_body, v_sentiment,
     v_impact, v_tpl.vol_multiplier,
     now(), now() + make_interval(secs => v_tpl.duration_seconds));
end;
$$;

-- ----------------------------------------------------------------------------
-- Extra templates for headline variety. Bodies can use the new tokens directly.
-- ----------------------------------------------------------------------------
insert into public.event_templates
  (code, scope, headline_template, body_template,
   fv_impact_min, fv_impact_max, vol_multiplier, duration_seconds, weight, class_id) values
  ('insider_buy',    'asset', 'Insiders load up on {name}',
   'Filings show {symbol} executives bought heavily — usually a vote of confidence.',
   0.02, 0.07, 1.3, 700, 1.5, 'stocks'),
  ('short_report',   'asset', 'Short-seller targets {name}',
   'A widely-followed bear published a scathing report on {symbol}.',
   -0.12, -0.05, 2.0, 1000, 1.2, 'stocks'),
  ('patent_win',     'asset', '{name} wins a landmark patent case',
   'A court ruling hands {symbol} years of protected upside.',
   0.03, 0.09, 1.4, 800, 1, 'stocks'),
  ('supply_shock',   'asset', 'Supply-chain snarl hits {name}',
   'Component shortages threaten to dent output at {symbol}.',
   -0.08, -0.03, 1.6, 900, 1.2, 'stocks'),
  ('viral_moment',   'asset', '{name} goes viral for the right reasons',
   'A social-media moment put {symbol} in front of millions of new customers.',
   0.02, 0.08, 1.5, 600, 1.2, 'stocks'),
  ('sector_rotation','sector', 'Money rotates into {sector}',
   'Fund managers are rotating fresh capital toward the {sector} sector.',
   0.02, 0.06, 1.3, 900, 1.5, null),
  ('inflation_cool', 'market', 'Inflation cools faster than expected',
   'A soft price print revives hopes for easier policy ahead.',
   0.02, 0.05, 1.2, 1100, 1, null),
  ('geopolitics',    'market', 'Geopolitical flare-up jolts risk appetite',
   'Headlines from abroad send traders scrambling to reprice risk.',
   -0.06, -0.01, 1.7, 1200, 0.9, null),
  ('stablecoin_wobble','sector', 'Stablecoin wobble spooks crypto',
   'A brief de-peg reminded everyone how reflexive digital assets can be.',
   -0.14, -0.04, 2.0, 1000, 0.8, 'crypto'),
  ('etf_inflows',    'asset', 'Record inflows chase {name}',
   'A flood of ETF money is piling into {symbol}.',
   0.05, 0.16, 1.9, 900, 1, 'crypto')
on conflict (code) do nothing;
