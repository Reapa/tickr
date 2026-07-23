-- ============================================================================
-- Migration 35: net-worth milestone ladder (fixes the progression desert)
--
-- Between the existing class-unlock gates ($50k real-estate, $250k companies)
-- there was a long stretch with nothing to aim at. This adds a ladder of
-- net-worth milestones — always one visible on the horizon — each awarding a
-- reward crate + XP and a rank title. Milestones are claimed lazily (a client
-- RPC called on the Portfolio screen), grant once, and are permanent even if
-- net worth later dips. Cosmetics/XP only, via the crate system — no cash.
-- ============================================================================

create table public.milestones (
  id         serial primary key,
  net_worth  numeric not null unique,
  title      text not null,
  crate_tier text not null check (crate_tier in ('common', 'rare', 'legendary')),
  reward_xp  int not null default 0,
  sort_order int not null
);

create table public.user_milestones (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  milestone_id int  not null references public.milestones (id),
  reached_at   timestamptz not null default now(),
  primary key (user_id, milestone_id)
);

alter table public.milestones      enable row level security;
alter table public.user_milestones enable row level security;
grant select on public.milestones to anon, authenticated;
grant select on public.user_milestones to authenticated;
create policy "milestones readable" on public.milestones for select using (true);
create policy "own milestones" on public.user_milestones for select
  using (user_id = (select auth.uid()));

insert into public.milestones (net_worth, title, crate_tier, reward_xp, sort_order) values
  (  15000, 'Getting Started', 'common',    100, 1),
  (  20000, 'In the Game',     'common',    150, 2),
  (  30000, 'Momentum',        'common',    200, 3),
  (  50000, 'Property Ladder', 'rare',      300, 4),
  (  75000, 'High Roller',     'rare',      400, 5),
  ( 120000, 'Six Figures',     'rare',      600, 6),
  ( 200000, 'Serious Money',   'legendary', 800, 7),
  ( 350000, 'Market Mover',    'legendary',1000, 8),
  ( 500000, 'Half a Milli',    'legendary',1200, 9),
  (1000000, 'Millionaire',     'legendary',2000, 10);

-- ----------------------------------------------------------------------------
-- Claim any milestones the caller's current net worth has reached but not yet
-- collected. Grants a crate + XP per milestone; returns the newly reached ones
-- so the client can celebrate. Idempotent — reached milestones are recorded.
-- ----------------------------------------------------------------------------
create or replace function public.claim_milestones()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user  uuid := auth.uid();
  v_nw    numeric;
  v_m     record;
  v_newly jsonb := '[]'::jsonb;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select net_worth into v_nw from public.profiles where id = v_user;

  for v_m in
    select m.* from public.milestones m
     where m.net_worth <= v_nw
       and not exists (select 1 from public.user_milestones um
                        where um.user_id = v_user and um.milestone_id = m.id)
     order by m.net_worth
  loop
    insert into public.user_milestones (user_id, milestone_id)
    values (v_user, v_m.id);
    perform game.grant_crate(v_user, v_m.crate_tier, 'milestone');
    if v_m.reward_xp > 0 then
      update public.profiles set xp = xp + v_m.reward_xp, updated_at = now()
       where id = v_user;
    end if;
    v_newly := v_newly || jsonb_build_object(
      'title', v_m.title, 'net_worth', v_m.net_worth,
      'crate_tier', v_m.crate_tier, 'xp', v_m.reward_xp);
  end loop;

  return jsonb_build_object('newly_reached', v_newly);
end;
$$;

grant execute on function public.claim_milestones() to authenticated;
