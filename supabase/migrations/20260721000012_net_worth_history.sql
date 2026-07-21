-- ============================================================================
-- Migration 12: per-player net-worth history
--
-- Recorded by market_tick() after the net-worth refresh; powers the
-- portfolio-value-over-time chart. Pruned on the same retention window as
-- price ticks.
-- ============================================================================

create table public.net_worth_history (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  net_worth  numeric(18,2) not null,
  tick_at    timestamptz not null default now()
);

create index net_worth_history_user_time_idx on public.net_worth_history (user_id, tick_at desc);
create index net_worth_history_time_idx on public.net_worth_history (tick_at);

alter table public.net_worth_history enable row level security;

create policy "own net worth history" on public.net_worth_history for select
  using (user_id = (select auth.uid()));

grant select on public.net_worth_history to authenticated;
