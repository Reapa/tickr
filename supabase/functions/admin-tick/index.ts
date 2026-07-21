// admin-tick: alternate driver for the market tick loop.
//
// The primary scheduler is pg_cron (see migration 8), which calls
// game.market_tick() every tick_seconds directly inside Postgres. If pg_cron
// is unavailable (some local setups) or you prefer an external scheduler,
// point any cron service (GitHub Actions, cron-job.org, Supabase scheduled
// functions) at this endpoint.
//
// Security: requires the service-role key. The underlying RPC
// (public.admin_run_tick) additionally re-checks the caller's role, and the
// tick itself takes an advisory lock, so double-driving pg_cron + this
// function is safe (one of them just no-ops).
//
// Invoke:
//   curl -X POST https://<project>.supabase.co/functions/v1/admin-tick \
//     -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"

import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request): Promise<Response> => {
  const auth = req.headers.get("Authorization") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  if (!serviceKey || auth !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: "service role required" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    serviceKey,
  );

  const started = performance.now();
  const { error } = await supabase.rpc("admin_run_tick");

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(
    JSON.stringify({ ok: true, ms: Math.round(performance.now() - started) }),
    { headers: { "Content-Type": "application/json" } },
  );
});
