-- ============================================================================
-- Migration 29: rare "major world events"
--
-- A dramatic tier of market-wide news — war, pandemics, central-bank shocks,
-- breakthroughs — that hits everything, is much rarer than normal news, and is
-- surfaced by the client as a prominent banner. Impacts are large but bounded;
-- the anchor model (migration 28) means even a crash recovers over time.
-- ============================================================================
alter table public.event_templates add column is_major boolean not null default false;
alter table public.market_events   add column is_major boolean not null default false;

-- Clients need to know which live event is a "major" one (to show the banner).
grant select (is_major) on public.market_events to anon, authenticated;

-- Fraction of spawns that are a major world event instead of normal news.
insert into public.game_config (key, value, description) values
  ('major_event_share', '0.003',
   'Share of spawned events that are rare market-wide "major" events (war, etc.).')
on conflict (key) do nothing;

-- Major templates: market scope, big (bounded) impact, long duration, high vol.
insert into public.event_templates
  (code, scope, headline_template, body_template,
   fv_impact_min, fv_impact_max, vol_multiplier, duration_seconds, weight, class_id, is_major) values
  ('major_war',            'market', 'War breaks out — global markets in turmoil',
   'Conflict has erupted between major powers. Investors flee risk assets for safety as uncertainty spikes.',
   -0.15, -0.06, 3.0, 3600, 1.0, null, true),
  ('major_ceasefire',      'market', 'Surprise ceasefire lifts world markets',
   'A breakthrough truce has been announced. Relief rallies sweep every exchange.',
   0.05, 0.12, 2.0, 2400, 1.0, null, true),
  ('major_pandemic',       'market', 'New pandemic fears grip the globe',
   'Health authorities warn of a fast-spreading outbreak. Markets brace for disruption and lockdowns.',
   -0.14, -0.05, 2.8, 3600, 0.9, null, true),
  ('major_breakthrough',   'market', 'Medical breakthrough electrifies markets',
   'Scientists unveil a landmark treatment. Optimism floods across every sector.',
   0.05, 0.13, 2.2, 2400, 0.8, null, true),
  ('major_emergency_cut',  'market', 'Central banks slash rates in emergency move',
   'A coordinated emergency cut floods the system with cheap money. Risk assets soar.',
   0.04, 0.10, 2.0, 2400, 1.0, null, true),
  ('major_rate_shock',     'market', 'Shock rate hike stuns global markets',
   'An unexpected jumbo hike sends borrowing costs spiking. Markets reel across the board.',
   -0.10, -0.04, 2.0, 2400, 1.0, null, true),
  ('major_bank_crisis',    'market', 'Banking crisis rattles the financial system',
   'A major lender is teetering and contagion fears are spreading fast.',
   -0.13, -0.05, 3.0, 3600, 0.7, null, true),
  ('major_trade_deal',     'market', 'Historic global trade deal signed',
   'The largest trade pact in a generation clears its final hurdle. Growth expectations jump.',
   0.04, 0.11, 1.8, 2400, 0.9, null, true),
  ('major_address',        'market', 'President addresses the nation on the economy',
   'A closely-watched speech lays out sweeping new policy. Traders parse every word.',
   -0.05, 0.06, 2.2, 1800, 1.2, null, true),
  ('major_tech_leap',      'market', 'Breakthrough technology reshapes the economy',
   'A transformative leap has analysts racing to reprice the future.',
   0.05, 0.14, 2.4, 3000, 0.8, null, true),
  ('major_disaster',       'market', 'Catastrophic disaster disrupts global supply',
   'A major disaster has struck a critical hub. Supply chains buckle and markets slide.',
   -0.11, -0.04, 2.6, 3000, 0.8, null, true),
  ('major_election',       'market', 'Election shock upends the political order',
   'An upset result blindsides markets. Uncertainty grips every asset class.',
   -0.09, 0.03, 2.4, 2400, 1.0, null, true)
on conflict (code) do nothing;

-- ----------------------------------------------------------------------------
-- Spawn: occasionally draws from the major pool instead of normal news, and
-- stamps the event as major. (Redefines migration 23's version; drop first so
-- the no-arg signature is replaced cleanly.)
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
     fv_impact, vol_multiplier, starts_at, ends_at, is_major)
  values
    (v_tpl.code, v_tpl.scope, v_asset.id, v_sector, v_headline, v_body, v_sentiment,
     v_impact, v_tpl.vol_multiplier,
     now(), now() + make_interval(secs => v_tpl.duration_seconds), v_major);
end;
$$;
