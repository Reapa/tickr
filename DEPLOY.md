# Deploying Tickr

The app has two hosted pieces: a **Supabase** project (database, auth, realtime,
the tick loop) and the **Flutter web** build on **GitHub Pages**.

## Backend — Supabase (hosted)

Project: `fvfzoiyxymrvyfguiooh` · URL `https://fvfzoiyxymrvyfguiooh.supabase.co` (eu-west-1).

To (re)provision a Supabase project from scratch:

1. **Push the schema** (all migrations):
   ```
   supabase db push --db-url "postgresql://postgres.<ref>:<db-pass>@aws-0-<region>.pooler.supabase.com:5432/postgres"
   ```
   Use the **Session pooler** URI (IPv4) from the dashboard's *Connect* dialog — the
   direct `db.<ref>.supabase.co` host is IPv6-only on the free tier.

2. **Load seed data** (assets, news templates, missions, Season 1):
   ```
   psql "<pooler-url>" -f supabase/seed.sql
   ```
   Migrations do not run the seed; it must be applied once by hand on a hosted project.

3. **Turn on the market tick** (pg_cron, every 5s):
   ```sql
   create extension if not exists pg_cron;
   select cron.schedule('market-tick', '5 seconds', 'select game.market_tick();');
   ```

4. **Optional — always-open markets for testing** (so prices move regardless of
   the time-of-day market-hours rules):
   ```sql
   update public.game_config set value = 'true' where key = 'markets_always_open';
   ```

5. **Auth**: for a friction-free test, turn **Authentication → Email → "Confirm
   email" OFF** so players can sign up with email + password and start immediately.
   Google/Facebook login needs OAuth apps configured and is off by default.

## Frontend — GitHub Pages

`.github/workflows/deploy.yml` builds the Flutter web app and publishes it to Pages
on every push to `main`. The Supabase URL + anon key (a public client key) are baked
into the build command there. The `--base-href` is derived from the repo name, so the
site serves at `https://<user>.github.io/<repo>/`.

One-time setup on a new repo:
- Enable Pages with the **GitHub Actions** source (Settings → Pages), then push to
  `main` (or run the workflow manually). Nothing else to configure.

## Notes / caveats for the current test deploy

- Deep-link refreshes fall back to `404.html` (a copy of `index.html`), so the SPA
  keeps working; the in-app URL just resets to root on a hard refresh.
- The tick loop and all economy logic run server-side, so the hosted market keeps
  moving even with nobody connected.
- To point a local `flutter run` at the hosted backend instead of a local
  `supabase start`, pass `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`.
