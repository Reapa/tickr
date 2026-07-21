# TradingGame — Development Handoff

*Written 2026-07-21 for the next developer/designer (Opus). Product owner: Justin.*
*Read [ARCHITECTURE.md](ARCHITECTURE.md) first for the design, [README.md](README.md) for setup. This document is what those two don't tell you: current state, hard-won environment facts, guardrails you must not break, and where the product owner wants this to go.*

## What this is

A cross-platform competitive **trading simulation game** (Flutter + Supabase). Fully simulated market — never real market data or money. Server-authoritative everything: prices, fills, cash, and holdings live in Postgres; the client renders. Product owner's direction, verbatim spirit: **"make this app awesome, and a lot more visualizations."** Fun, addictive, educational — in that spirit; the sim exists to teach supply/demand, news reaction, volatility, mean reversion, diversification, and risk management through play.

## Current state (all working, all committed on `main`)

- **Simulation**: `game.market_tick()` every 5s via pg_cron — GBM fair-value drift, news events (spawned from weighted templates, one-time fair-value shock + volatility window), decaying player order-flow price impact, mean reversion. Assets are parody companies (Googol, Envidia, Tesler Motors, SpaceY…).
- **Trading**: market buy/sell through `place_market_order()` (server-priced with spread); **take-profit / stop-loss** through `set_position_protection()` — pending `limit`/`stop` sell orders the tick executes at the live bid, with one-cancels-other cleanup and Realtime fill toasts.
- **Economy**: append-only `transactions` ledger; cash/holdings trigger-derived; `game.reconcile_ledger()` proves zero drift. Overdrafts and premium→cash conversion are impossible at the CHECK-constraint level.
- **Competition**: global/friends leaderboards, 14-day seasons by % return (auto-rollover, cosmetic + cash rewards), 24h/7d friend challenges — all resolved in the tick.
- **Progression**: stocks free → real estate $50k → companies (scaffolded, disabled). Missions (6) auto-evaluated server-side, rewards through the ledger.
- **App**: Riverpod 3 / go_router 17 / fl_chart 1.2. Market list with ticker tape + price flashes; candle charts (1m–1h) with avg-cost/TP/SL overlay markers; portfolio with net-worth chart, Today P&L, diversification bar, Protect/Close position actions; always-visible positions bar docked above the nav; compete/social/missions/store screens.
- **Tests**: 108 pgTAP assertions (4 suites: economy, monetization-safety+RLS, competition, TP/SL) — run `supabase test db`. 23 Dart tests mirroring server formulas — `flutter test`. **All passing against the live local stack.**

## Environment facts (this specific dev machine)

- **Flutter SDK**: `C:\Users\justi\flutter` (not on PATH — prepend `C:\Users\justi\flutter\bin`). Developer Mode is ON. Only usable device: **Edge** (`flutter run -d edge`); no Chrome, no Android SDK, no VS C++ workload.
- **Backend runs inside WSL Debian** (no Docker Desktop): Docker Engine + Supabase CLI 2.109.1. Invoke as:
  `wsl -u root -- sh -c 'cd /mnt/d/Development/Projects/TradingGame && supabase <cmd>'`
- **WSL idle-kills its VM** — mitigated via `%UserProfile%\.wslconfig` (`vmIdleTimeout=-1`) plus a keepalive process; if Supabase seems dead, the VM probably cycled: wait for `pg_isready`, containers auto-restart.
- The **db container restarts briefly after every `supabase test db`** — wait for `pg_isready` before the next command.
- App connects with zero flags: `Env` defaults to `http://127.0.0.1:54321` + the CLI's shared local publishable key.
- During this session some migrations were **live-applied** to the running DB (they're all also in `supabase/migrations/`, so a fresh `db reset` is equivalent). If dev DB and migrations ever diverge, `supabase db reset` is the truth-maker (wipes local accounts).

## Guardrails — do not break these

1. **Server-authoritative economy.** Clients never compute prices or write economy tables. No table has INSERT/UPDATE/DELETE policies; every mutation is a SECURITY DEFINER RPC. Keep it that way.
2. **Everything through the ledger.** Any new money flow (leverage P&L, streak bonuses, whatever) must be `transactions` rows with a type added to the closed CHECK set — never a direct `cash_balance` update. `game.reconcile_ledger()` must stay empty; add pgTAP coverage for any new flow.
3. **Cosmetic-only monetization** is enforced by the closed CHECK sets on `transactions.type` and `premium_ledger.reason`. Never add a member that bridges the two economies. Test 02 exists to catch you.
4. **Hidden sim internals stay hidden**: `fair_value`, `flow`, sim params, event impact numbers are column-privilege-restricted. New client queries must name columns explicitly (`select *` on `assets`/`market_events` will 401).
5. **Tests are hermetic-by-transaction** but the dev DB has live players: suites that rank globally must purge non-fixture users inside their rolled-back transaction (see 03), and price-sensitive suites must pin prices (the market ticks every 5s *during* test runs — see 01/04 headers).
6. Riverpod: **don't couple a FutureProvider to a live stream via `select()`** — it caused a "setState during build" crash on tab resume; the pattern here is timer-based `invalidateSelf` (see `priceHistoryProvider`). Also avoid supabase `.stream()` — its client merge duplicated rows; use fetch + Realtime-refetch (see `watchHoldings`).

## Product owner's stated wants (prioritized backlog)

1. ~~Leverage trading~~ — **SHIPPED** (migration 15, test suite 05, `features/leverage/`): CFD-style long/short positions at 5–100×, margin-posted, liquidation at entry·(1∓1/leverage) enforced by the tick, TP/SL on positions, broker-license unlock ($25k), 50×/100× level-gated, all flows through the ledger (`margin_open`/`margin_close`), net worth marks open equity. Loss is hard-capped at margin. What's left here: leaderboard/season implications of leverage (a 100× win skews % return — owner hasn't weighed in), and a "liquidation history" stats view.
2. **More/better visualizations** — owner wants the app to feel like a pro trading floor. Shipped: candles with interval switching + marker overlays, sparklines on the market list, sector color system, danger meters on leveraged positions, ticker tape, price flashes, gradient header, **Top Movers strip** (market screen; `get_movers()` RPC migration 17), **allocation donut** (portfolio; cash + spot holdings by sector, net worth in center), **level-up celebration overlay** (confetti custom-painter + banner, fired from the shell on level increase). Good next ideas: richer candle interactions (crosshair, pinch-zoom, volume bars — `trades` has the data), season-race progress visual, leaderboard movement animations, a sector heatmap, depth-style flow visual (server would need a sanitized flow signal — guardrail 4).
3. **Market hours + volatile universe** — **SHIPPED** (migration 16): `assets.market_hours` (24_7/24_5/weekday_day) + `game.is_market_open()`, enforced across every engine path; closed markets freeze. Crypto (Bitcorn/Ethereal/Solami/Dogercoin, 24/7, vol 1.2–2.5) and forex majors (24/5) seeded; unlocks $2.5k / $10k. Client shows open/closed status and 24/7 badges. Left to consider: a dedicated "always-open" tab or filter if the class-grouping isn't enough; a visible market-hours schedule/clock; per-session weekend crypto events.
4. **Fun/addictive round two** (proposed to owner, well received): daily streaks (through the ledger), live "big trades" feed (needs an anonymized public trades view — respect guardrail 4), news alerts for held assets.
4. Owner feedback patterns to honor: **intuitive over dense** (TP/SL got %-or-$ modes with quick chips; the leverage ticket leads with the liquidation warning and "max loss" for the same reason), visible positions everywhere (positions bar), playful tone (parody names, emoji toasts).
5. **Market-feel tuning (2026-07-21 audit)**: liquidity cut 5× so player trades visibly move prices; event spawn 3%/tick (~2.8 min between news); avg tick move ~0.04%; time compression 1 game-year = 7 days. All knobs in `game_config` + per-asset columns — retune freely as player count grows (liquidity should scale back UP with real concurrency).

## Known rough edges

- Season/challenge/leaderboard flows are SQL-tested but the **two-player client flow has never been human-tested** (needs two browser sessions swapping friend codes).
- OAuth providers are placeholder-credentialed locally; email/password is the tested path. No hosted Supabase project exists yet.
- `flutter run -d edge` sessions are launched by the assistant as background tasks; a session dies with its task. `--no-hot` is used because stdin isn't attached (no hot reload) — every change needs a relaunch (~30s).
- No CI. First good next step: GitHub Actions running `flutter analyze` + `flutter test` + `supabase start && supabase test db`.
- Windows/macOS/iOS/Android targets are scaffolded but never built on this machine (toolchains absent). Web (Edge) is the verified target.
- Candle marker overlays use thin range-annotation bands (fl_chart's CandlestickChart lacks ExtraLines); the legend below the chart carries exact values.

## Working rhythm that worked

Tick-driven verification: make a change → `flutter analyze` + `flutter test` → live-apply SQL via `docker exec -i supabase_db_tradinggame psql -U postgres` → `supabase test db` → relaunch Edge → keep a grep monitor on the run log for exceptions. Commit per feature with explanatory bodies. The pgTAP suites are the safety net for anything touching money — extend them first when building leverage.
