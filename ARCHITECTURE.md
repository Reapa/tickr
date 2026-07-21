# TradingGame — Architecture Plan

A cross-platform, competitive **trading simulation game**. All markets and money are simulated in-game; no real market data, no real money. Players trade on a live, server-driven market, learn cause→effect from news events, and compete on leaderboards, in seasons, and head-to-head.

## 1. Stack

| Layer | Choice | Notes |
|---|---|---|
| Client | Flutter (Dart) | One codebase: iOS, Android, Windows, macOS, Web. Factored so Wear OS / Steam targets can be added later. |
| State mgmt | Riverpod (`flutter_riverpod`) | Compile-safe DI, no BuildContext coupling, first-class support for streaming/async state — ideal for Realtime price feeds and highly testable. |
| Routing | `go_router` | Declarative, deep-link ready (invite links), redirect-based auth guarding. |
| Charts | `fl_chart` | Price + portfolio-value charts. |
| Backend | Supabase | Postgres + RLS, Auth (Google/Facebook/email), Realtime, Edge Functions, `pg_cron`. |
| Server logic | Postgres functions (PL/pgSQL) | The entire economy lives in the database. `pg_cron` drives the tick. A TS Edge Function exists only as an alternate tick trigger. |

## 2. Core principles

1. **Server-authoritative market.** Clients never compute prices or validate trades. Every economy mutation goes through `SECURITY DEFINER` Postgres functions (RPCs). Direct table writes are impossible: RLS grants read policies only — there are **no insert/update policies on economy tables**.
2. **Everything reconciles to a ledger.** `transactions` is append-only. `profiles.cash_balance` and `holdings` are maintained by triggers **from** ledger inserts and can always be re-derived by `SUM()`. A reconciliation function asserts this invariant (and is under test).
3. **Tick loop.** `market_tick()` advances the simulation every N seconds (configurable in `game_config`, default 5s) via `pg_cron`. Each tick: move fair values, apply/expire events, decay order-flow pressure, recompute traded prices, write `price_ticks`, refresh net worths, resolve due seasons/challenges.
4. **Realtime = render, not compute.** Clients subscribe to `assets` (prices), `market_events` (news), `profiles` (leaderboard/net-worth) via Supabase Realtime and just draw.
5. **Cosmetic-only monetization, enforced in the schema.** Premium currency lives in its own append-only ledger whose `reason` is a closed CHECK set (grants, cosmetic purchases, season rewards). The cash ledger's `type` is a closed CHECK set with **no** premium-conversion member. No function bridges the two ledgers → premium can never become trading power, by construction.

## 3. Simulation engine (market-maker model)

Each asset has a hidden `fair_value` and a public `current_price`.

Per tick (dt = tick seconds / seconds-per-game-year):

```
z          = N(0,1)                      -- Box–Muller in SQL
sigma_eff  = base_volatility * event_vol_multiplier (product of active events)
fair_value = fair_value * exp((drift - sigma_eff²/2)*dt + sigma_eff*sqrt(dt)*z)

flow       = flow * exp(-tick/flow_halflife)          -- decaying net player order flow
impact     = impact_coef * tanh(flow / liquidity)     -- bounded price impact
target     = fair_value * (1 + impact)
price      = price + reversion_speed * (target - price)  -- mean reversion toward fair value
```

- **Events**: rows in `market_events` generated from `event_templates` (earnings beat/miss, sector news, macro shocks) with a small per-tick spawn probability. On activation they shock `fair_value` (× (1+impact)) once and multiply volatility while active. They are the in-game news feed — players see the cause of every move.
- **Player flow**: a market buy adds `+notional` to the asset's `flow` accumulator, a sell adds `−notional`; the next tick's price responds. Net buying pushes price above fair value, then mean-reverts. This teaches supply & demand + mean reversion honestly.
- **Fills**: market orders fill instantly at `current_price` ± half the asset's `spread` (buys pay the ask). Slippage-free beyond spread in v1.
- **Order book seam**: `orders` carries `order_type` (`market` now; `limit` enum member already present) with `limit_price`/`status` columns, and execution is isolated in `execute_order()` — a CLOB matcher can replace the market-maker fill later without schema breakage.

Teaching goals wired in: supply & demand (flow impact), news reaction (events), volatility (sigma per asset + event multipliers), mean reversion (price↔fair value), diversification (sector tags + missions).

## 4. Data model (all as versioned migrations)

- `game_config` — key/value knobs (tick seconds, starting cash, flow half-life…).
- `profiles` — display name, cash (ledger-derived), XP/level, equipped cosmetics, net worth (tick-refreshed), friend code.
- `asset_classes` — `stocks` (0 cost, auto-unlocked), `real_estate`, `companies` (scaffold); `unlock_cost` gates entry. `user_asset_class_unlocks` records purchases.
- `assets` — instrument, class, sector, hidden `fair_value` (column privilege-hidden via view), `current_price`, sim params (volatility, drift, liquidity, spread), `flow`.
- `price_ticks` — per-asset time series for charts.
- `orders` / `trades` — intents and fills.
- `transactions` — append-only cash+holdings ledger (single source of truth).
- `holdings` — current positions + avg cost (trigger-materialized from ledger).
- `event_templates` / `market_events` — news feed + sim shocks.
- `seasons` / `season_scores` — fixed-length competitive periods ranked by % return; cosmetic rewards on close.
- `leaderboard` — view over profiles (global) + friends filter.
- `friendships` (friend-code based; no platform import) / `friend_challenges` (24h/7d head-to-head by % return).
- `missions` / `user_missions` — educational challenges, server-evaluated after trades/ticks.
- `cosmetics` / `user_cosmetics` / `premium_ledger` — cosmetic-only store (stubbed purchases, no real IAP in v1).

## 5. Flutter structure (feature-first)

```
lib/
  core/            # supabase client, env, router, theme, formatting, shared widgets
  features/
    auth/          # sign in/up, OAuth, session redirect
    onboarding/
    market/        # asset list, asset detail + chart, news feed
    trading/       # order ticket, confirmation
    portfolio/     # holdings, P&L, portfolio-value chart
    competition/   # leaderboard (global/friends), seasons, challenges
    social/        # friends, friend codes, invites
    missions/
    store/         # cosmetic store stub + loadout
    profile/
```

Each feature: `data/` (repositories over Supabase), `domain/` (models), `presentation/` (providers + widgets). Repositories are the only layer that touches `supabase_flutter`, so a watch companion or Steam build reuses everything below presentation.

## 6. Phase breakdown

| Phase | Deliverable | Commit |
|---|---|---|
| 0 | Repo scaffold, this document, tooling | `phase-0` |
| 1 | Schema + RLS migrations (all tables, policies, triggers) | `phase-1` |
| 2 | Simulation + trading engine: `market_tick()`, `execute_order()`, events, pg_cron, seeds | `phase-2` |
| 3 | Competition + progression + missions + cosmetics SQL; pgTAP economy tests | `phase-3` |
| 4 | Flutter scaffold: core, theme, router, auth, onboarding | `phase-4` |
| 5 | Market, trading, portfolio UI (Realtime, charts, news) | `phase-5` |
| 6 | Competition, social, missions, store UI | `phase-6` |
| 7 | Dart tests on economy view-logic, README, polish | `phase-7` |

## 7. Defaults chosen (confirm with product owner)

Tick 5s · starting cash $10,000 · real estate unlock $50,000 · companies unlock $250,000 (scaffold) · season length 14 days · 16 seed stocks across 5 sectors + 5 real-estate assets + 3 scaffold companies · challenge windows 24h/7d · XP: 10/trade + mission rewards, level = floor(sqrt(xp/100)).
