# TradingGame

A cross-platform, competitive **trading simulation game**. Every market and every dollar is simulated in-game — no real market data, no real money, ever. Players trade a live, always-on market whose prices move for learnable reasons (news events + other players' order flow), climb a global leaderboard, race friends head-to-head, compete in resetting seasons, and buy their way into new asset classes with in-game earnings.

- **Frontend:** Flutter (iOS, Android, Windows, macOS, Web from one codebase)
- **Backend:** Supabase (Postgres + RLS, Auth, Realtime, Edge Functions, pg_cron)
- **Design doc:** [ARCHITECTURE.md](ARCHITECTURE.md) — read this first; it covers the simulation model, the ledger, and every design decision.

The market is **server-authoritative**: clients never compute prices or validate trades. Cash and holdings derive from an append-only ledger and always reconcile. Premium currency is **cosmetic-only by database constraint**, not by policy.

---

## Repository layout

```
ARCHITECTURE.md         The plan: simulation model, data model, phases
app/                    Flutter app (feature-first: lib/features/<feature>/{data,domain,presentation})
supabase/
  migrations/           Versioned schema: 12 migrations, fully commented
  seed.sql              Assets, news templates, missions, cosmetics, season 1
  tests/                pgTAP economy/monetization/competition tests
  functions/admin-tick/ Alternate tick driver (if pg_cron is unavailable)
  config.toml           Local dev config (auth providers via supabase/.env)
```

## Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel)
- [Supabase CLI](https://supabase.com/docs/guides/cli) + Docker (for the local stack)
- **Windows only:** enable Developer Mode (`start ms-settings:developers`) — Flutter needs symlink support to build plugins.

## 1. Backend setup

### Local (recommended for development)

```bash
cd supabase
supabase start          # boots Postgres, Auth, Realtime, Studio in Docker
supabase db reset       # applies all migrations + seed.sql
```

`db reset` leaves you with a playable market: 16 stocks across 5 sectors, 5 real-estate assets (locked behind a $50,000 buy-in), 14 news templates, 5 educational missions, 10 cosmetics, and Season 1 already running.

**Start the tick loop.** Migration 8 schedules `game.market_tick()` through pg_cron every 5 seconds automatically. If pg_cron isn't available in your environment, drive it externally instead:

```bash
supabase functions serve admin-tick   # then hit it on a timer:
curl -X POST http://127.0.0.1:54321/functions/v1/admin-tick \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```

Double-driving is safe — the tick takes an advisory lock and extra calls no-op. The tick interval lives in `game_config.tick_seconds`; if you change it, re-run the `cron.schedule` call from migration 8 to match.

### Hosted (Supabase Cloud)

1. Create a project, then: `supabase link --project-ref <ref>` and `supabase db push`.
2. Run `supabase/seed.sql` once via the SQL editor (or `psql`).
3. Enable the **pg_cron** extension (Dashboard → Database → Extensions) *before* pushing, or re-run the schedule block from migration 8 after enabling it.
4. Auth providers (Dashboard → Authentication → Providers):
   - **Email**: on by default.
   - **Google / Facebook**: create OAuth apps, paste client id + secret. Add the app's deep link `io.supabase.tradinggame://login-callback/` to the provider redirect allowlist for mobile/desktop.
   - Locally, put the same credentials in `supabase/.env` as `SUPABASE_AUTH_GOOGLE_CLIENT_ID` etc. (see `config.toml`; the file is gitignored).
   - **Steam** is roadmap: it uses legacy OpenID 2.0, not OAuth. The seam is an edge function that verifies the OpenID assertion and mints a session — nothing in the current auth code needs restructuring for it.

## 2. Running the app

```bash
cd app
flutter pub get

# Local backend (defaults point at supabase start's URL + demo anon key):
flutter run -d chrome            # Web
flutter run -d windows           # Windows desktop
flutter run -d macos             # macOS
flutter run -d <device-id>       # iOS / Android

# Hosted backend:
flutter run --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
            --dart-define=SUPABASE_ANON_KEY=<publishable-or-anon-key>
```

Android emulators can't see `127.0.0.1` — use `--dart-define=SUPABASE_URL=http://10.0.2.2:54321` against the local stack.

Sign up, and onboarding is automatic (a database trigger): $10,000 starting cash through the ledger, 200 gems, the stocks tier unlocked, all missions enrolled, and you're entered in the current season.

## 3. Tests

**Economy tests (the ones that must never break)** — pgTAP against the local stack:

```bash
cd supabase
supabase db reset && supabase test db
```

- `01_economy_test.sql` — order execution math (spread, notional, average cost), persisted rejections, unlock gating, net-worth calculation, ledger reconciliation, append-only + overdraft hardening (36 assertions).
- `02_monetization_rls_test.sql` — proves at the constraint level that premium currency can never become cash or trading power, plus store flow and RLS/column-privilege checks (27 assertions).
- `03_competition_test.sql` — friend codes, challenge lifecycle + resolution, season rollover with ranks and rewards (22 assertions).

**Dart tests** — client mirrors of the server formulas (P&L, net worth, % return, diversification weights, level curve):

```bash
cd app
flutter test && flutter analyze
```

## How the simulation works (short version)

Each asset has a hidden **fair value** and a public **traded price**. Every tick (5s):

1. Fair value drifts with random noise (geometric Brownian motion, per-asset volatility).
2. Active **news events** shock fair value once at start and raise volatility while live — the news feed shows players *why* prices moved.
3. Player order flow accumulates per asset and decays (60s half-life). Net buying pushes the traded price above fair value (`impact = impact_coef · tanh(flow / liquidity)`), net selling below.
4. The traded price mean-reverts toward fair value ± impact.

That models, honestly enough to teach: supply & demand, news reaction, volatility, mean reversion, and (via sectors + missions) diversification. Order execution is a market-maker model — the schema (order_type/limit_price/status on `orders`) is ready for limit orders and a real order book later.

## Guarantees worth knowing about

- **Ledger-first economy.** `transactions` is append-only (trigger-enforced); `cash_balance` and `holdings` are maintained *by* the ledger trigger and re-derivable via `SUM()`. `game.reconcile_ledger()` returns any drift (tested to return none).
- **Clients can't cheat.** No table has an insert/update/delete policy; every economy write is a `SECURITY DEFINER` RPC. `fair_value`, order-flow, sim parameters, and event impact numbers are invisible to clients via column-level grants.
- **Cosmetic-only monetization.** `transactions.type` and `premium_ledger.reason` are closed CHECK sets with no member that converts between the currencies — the "gems never buy advantage" rule is unfalsifiable at the schema level. Gem purchases are stubbed (free) in v1; swap `stub_purchase_premium` for real receipt validation to go live.

## Roadmap (deliberately not built, deliberately not blocked)

- Limit orders → central limit order book (schema seam in place)
- Steam login (OpenID 2.0 edge function) + Steamworks distribution
- Wear OS / watchOS companions (repositories are UI-independent; watch apps reuse data + domain layers)
- Platform friend-graph import (friend codes never depended on it)
- Real IAP (App Store / Play Billing receipt validation)
- The "companies" asset class (scaffolded: class + assets seeded, disabled)
