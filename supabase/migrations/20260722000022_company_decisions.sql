-- ============================================================================
-- Migration 42: Companies Phase 2 "Run it" — strategic decisions.
--
-- The interactive heart. Each company periodically surfaces a decision: mostly
-- proactive REINVEST choices (R&D / marketing / expand — different cost & payoff
-- profiles) and occasional reactive EVENTS (a rival, a lawsuit, a boom). The
-- player picks; the server rolls a BOUNDED outcome and applies it to the
-- company's revenue (and thus valuation). Honest & un-gameable: the option
-- ranges are fixed, only the roll is random, and growth is capped to a multiple
-- of capital actually invested — so to grow further you must keep investing.
--
-- Light-touch: a decision every ~5h per company with a generous response window;
-- ignoring one is never punishing beyond the odd mild event default.
-- ============================================================================

-- 1. Config ------------------------------------------------------------------
insert into public.game_config (key, value, description) values
  ('company_decision_hours',        '5',    'Hours between a company''s decisions.'),
  ('company_decision_window_hours', '20',   'Hours a player has to answer before it expires.'),
  ('company_cost_unit_pct',         '0.05', 'A cost_factor of 1.0 costs this fraction of valuation.'),
  ('company_growth_cap',            '5',    'Valuation is capped at invested_basis * this multiple.')
on conflict (key) do nothing;

-- 2. Decision templates ------------------------------------------------------
-- options jsonb: array of {key,label,blurb,cost_factor,cash,rev_min,rev_max,level}.
-- cost = round(cost_factor * valuation * company_cost_unit_pct). The roll picks
-- rev_mult uniformly in [rev_min,rev_max]; effects live here (server-side), not
-- on the per-instance row, so nothing leaks an instance's answer.
create table public.company_decision_templates (
  id          text primary key,
  kind        text not null check (kind in ('reinvest','event')),
  weight      numeric not null default 1,
  prompt      text not null,
  default_key text,                    -- outcome applied if the player ignores it
  options     jsonb not null
);

insert into public.company_decision_templates (id, kind, weight, prompt, default_key, options) values
  ('grow', 'reinvest', 7,
   'Profits are in at {name}. Where do you reinvest?', null,
   '[{"key":"rnd","label":"R&D","blurb":"Slow burn, big ceiling","cost_factor":1.0,"cash":true,"rev_min":0.98,"rev_max":1.30,"level":0},
     {"key":"marketing","label":"Marketing push","blurb":"Reliable, modest bump","cost_factor":0.6,"cash":true,"rev_min":1.03,"rev_max":1.12,"level":0},
     {"key":"expand","label":"Expand operations","blurb":"Costly but durable","cost_factor":1.4,"cash":true,"rev_min":1.05,"rev_max":1.18,"level":1}]'::jsonb),
  ('rival', 'event', 1.5,
   'A rival is undercutting {name}. How do you respond?', 'hold',
   '[{"key":"cut","label":"Cut prices","blurb":"Protect share, thinner margins","cost_factor":0,"cash":false,"rev_min":0.92,"rev_max":1.03,"level":0},
     {"key":"hold","label":"Hold firm","blurb":"Ride it out — risky","cost_factor":0,"cash":false,"rev_min":0.85,"rev_max":1.10,"level":0},
     {"key":"innovate","label":"Out-innovate them","blurb":"Costs cash, high upside","cost_factor":1.0,"cash":true,"rev_min":1.00,"rev_max":1.22,"level":0}]'::jsonb),
  ('lawsuit', 'event', 1.0,
   '{name} is hit with a lawsuit. What now?', 'fight',
   '[{"key":"settle","label":"Settle quietly","blurb":"Pay to make it go away","cost_factor":0.8,"cash":true,"rev_min":1.00,"rev_max":1.00,"level":0},
     {"key":"fight","label":"Fight it in court","blurb":"No cash now, but risky","cost_factor":0,"cash":false,"rev_min":0.82,"rev_max":1.06,"level":0}]'::jsonb),
  ('boom', 'event', 1.5,
   'Demand is surging for {name}. Seize it?', 'ride',
   '[{"key":"ride","label":"Ride the wave","blurb":"Bank the upside","cost_factor":0,"cash":false,"rev_min":1.04,"rev_max":1.15,"level":0},
     {"key":"double","label":"Double down","blurb":"Invest to capture more","cost_factor":1.0,"cash":true,"rev_min":1.10,"rev_max":1.30,"level":1}]'::jsonb);

-- 3. Decision instances ------------------------------------------------------
create table public.company_decisions (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.user_companies (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  template_id text not null references public.company_decision_templates (id),
  kind        text not null,
  prompt      text not null,
  options     jsonb not null,     -- display: [{key,label,blurb,cost}]
  status      text not null default 'pending' check (status in ('pending','resolved','expired')),
  chosen_key  text,
  outcome     jsonb,
  opens_at    timestamptz not null default now(),
  expires_at  timestamptz not null,
  resolved_at timestamptz
);
create index company_decisions_user_idx on public.company_decisions (user_id) where status = 'pending';
alter table public.company_decisions enable row level security;
create policy "own decisions readable" on public.company_decisions
  for select using (user_id = auth.uid());
grant select on public.company_decisions to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.company_decisions;
  end if;
end $$;

-- 4. Poster: expire overdue, then post one pending decision per due company ---
create or replace function game.post_company_decisions()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_unit   numeric := coalesce(game.config_numeric('company_cost_unit_pct'), 0.05);
  v_window numeric := coalesce(game.config_numeric('company_decision_window_hours'), 20);
  v_c      record;
  v_t      public.company_decision_templates%rowtype;
  v_opts   jsonb;
  v_o      jsonb;
begin
  -- Expire unanswered decisions, applying the template default (if any).
  for v_c in
    select d.id as decision_id, d.template_id, d.chosen_key, d.company_id
      from public.company_decisions d
     where d.status = 'pending' and d.expires_at < now()
  loop
    perform game.apply_decision_default(v_c.decision_id);
  end loop;

  -- Post a fresh decision for each private company that's due and idle.
  for v_c in
    select c.* from public.user_companies c
     where c.status = 'private'
       and c.next_decision_at is not null and c.next_decision_at <= now()
       and not exists (select 1 from public.company_decisions d
                        where d.company_id = c.id and d.status = 'pending')
  loop
    -- Weighted template pick (exponential sampling).
    select * into v_t from public.company_decision_templates
     order by -ln(random()) / weight limit 1;
    -- Build display options with concrete cash costs from company size.
    v_opts := '[]'::jsonb;
    for v_o in select value from jsonb_array_elements(v_t.options) loop
      v_opts := v_opts || jsonb_build_array(jsonb_build_object(
        'key',   v_o->>'key',
        'label', v_o->>'label',
        'blurb', v_o->>'blurb',
        'cost',  round((coalesce((v_o->>'cost_factor')::numeric,0) * v_c.valuation * v_unit)::numeric, 2)
      ));
    end loop;
    insert into public.company_decisions
      (company_id, user_id, template_id, kind, prompt, options, expires_at)
    values (v_c.id, v_c.user_id, v_t.id, v_t.kind,
            game.render_template(v_t.prompt, jsonb_build_object('name', v_c.name)),
            v_opts, now() + make_interval(hours => v_window::int));
  end loop;
end $$;

-- Shared applier: given a company, a chosen template option, roll + apply.
create or replace function game.apply_company_option(
  p_company uuid, p_template text, p_key text, p_charge_cash boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_c    public.user_companies%rowtype;
  v_opt  jsonb;
  v_mult numeric;
  v_cost numeric;
  v_unit numeric := coalesce(game.config_numeric('company_cost_unit_pct'), 0.05);
  v_cap  numeric := coalesce(game.config_numeric('company_growth_cap'), 5);
  v_multiple numeric;
  v_new_rev numeric;
  v_new_val numeric;
  v_basis  numeric;
begin
  select * into v_c from public.user_companies where id = p_company for update;
  if not found then return jsonb_build_object('status','gone'); end if;

  select value into v_opt from jsonb_array_elements(
      (select options from public.company_decision_templates where id = p_template))
   where value->>'key' = p_key;
  if v_opt is null then return jsonb_build_object('status','bad_option'); end if;

  select revenue_multiple into v_multiple from public.company_industries
   where id = v_c.industry_id;

  v_cost := round((coalesce((v_opt->>'cost_factor')::numeric,0) * v_c.valuation * v_unit)::numeric, 2);
  v_basis := v_c.invested_basis;

  if p_charge_cash and (v_opt->>'cash')::boolean and v_cost > 0 then
    if (select cash_balance from public.profiles where id = v_c.user_id) < v_cost then
      return jsonb_build_object('status','insufficient_cash','cost', v_cost);
    end if;
    insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
    values (v_c.user_id, 'company_invest', -v_cost, 'company', v_c.id::text);
    v_basis := v_basis + v_cost;   -- capital invested raises the growth ceiling
  end if;

  v_mult := (v_opt->>'rev_min')::numeric
          + random() * ((v_opt->>'rev_max')::numeric - (v_opt->>'rev_min')::numeric);
  v_new_rev := round(v_c.revenue_rate * v_mult, 2);
  v_new_val := round(v_new_rev * v_multiple, 2);
  -- Growth cap: valuation can't exceed a multiple of capital actually invested.
  if v_new_val > v_basis * v_cap then
    v_new_val := round(v_basis * v_cap, 2);
    v_new_rev := round(v_new_val / v_multiple, 2);
  end if;

  update public.user_companies
     set revenue_rate = v_new_rev,
         valuation    = v_new_val,
         invested_basis = v_basis,
         level = level + coalesce((v_opt->>'level')::int, 0),
         next_decision_at = now() + make_interval(
           hours => coalesce(game.config_numeric('company_decision_hours'),5)::int)
   where id = v_c.id;

  return jsonb_build_object('status','ok','rev_mult', round(v_mult,4),
                            'cost', v_cost, 'new_revenue', v_new_rev,
                            'new_valuation', v_new_val,
                            'revenue_delta', v_new_rev - v_c.revenue_rate);
end $$;

-- Ignored decision → apply the template's default option (no cash charged).
create or replace function game.apply_decision_default(p_decision uuid)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_d  public.company_decisions%rowtype;
  v_def text;
  v_out jsonb;
begin
  select * into v_d from public.company_decisions where id = p_decision for update;
  if not found or v_d.status <> 'pending' then return; end if;
  select default_key into v_def from public.company_decision_templates where id = v_d.template_id;

  if v_def is not null then
    v_out := game.apply_company_option(v_d.company_id, v_d.template_id, v_def, false);
  else
    -- No default: just advance the clock, no change.
    update public.user_companies
       set next_decision_at = now() + make_interval(
             hours => coalesce(game.config_numeric('company_decision_hours'),5)::int)
     where id = v_d.company_id;
    v_out := jsonb_build_object('status','ignored');
  end if;

  update public.company_decisions
     set status = 'expired', chosen_key = v_def, outcome = v_out, resolved_at = now()
   where id = p_decision;
end $$;

-- 5. Player choice -----------------------------------------------------------
create or replace function public.make_company_decision(p_decision uuid, p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_d    public.company_decisions%rowtype;
  v_out  jsonb;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_d from public.company_decisions
   where id = p_decision and user_id = v_user for update;
  if not found then return jsonb_build_object('status','not_found'); end if;
  if v_d.status <> 'pending' then return jsonb_build_object('status','already_resolved'); end if;
  if not exists (select 1 from jsonb_array_elements(v_d.options)
                  where value->>'key' = p_key) then
    return jsonb_build_object('status','bad_option');
  end if;

  v_out := game.apply_company_option(v_d.company_id, v_d.template_id, p_key, true);
  if v_out->>'status' <> 'ok' then
    return v_out;  -- e.g. insufficient_cash: leave the decision open to retry
  end if;

  update public.company_decisions
     set status = 'resolved', chosen_key = p_key, outcome = v_out, resolved_at = now()
   where id = v_d.id;

  return v_out;
end $$;

grant execute on function public.make_company_decision(uuid, text) to authenticated;

-- 6. Schedule the poster (every 10 minutes) ----------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('post-company-decisions', '*/10 * * * *',
      $cron$ select game.post_company_decisions(); $cron$);
  end if;
end $$;
