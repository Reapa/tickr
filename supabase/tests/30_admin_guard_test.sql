-- ============================================================================
-- Privileged RPCs must refuse ordinary players.
--
-- Regression: admin_run_tick's guard tested `current_user`, which under
-- SECURITY DEFINER is the function owner rather than the caller, so the check
-- was permanently false and any signed-in player could drive the simulation.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));

select plan(5);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'authenticated', 'authenticated', 'nosy@example.test',
        '{"display_name": "Nosy"}'::jsonb);

-- A normal player, exactly as PostgREST would present them.
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);
select throws_ok('select public.admin_run_tick()', 'P0001',
  'admin_run_tick is service-role only',
  'a signed-in player cannot force a market tick');

-- Anon likewise.
select set_config('request.jwt.claims', '{"role": "anon"}', true);
select throws_ok('select public.admin_run_tick()', 'P0001',
  'admin_run_tick is service-role only',
  'an anonymous caller cannot force a market tick');

-- The edge function, which is the legitimate caller.
select set_config('request.jwt.claims', '{"role": "service_role"}', true);
select lives_ok('select public.admin_run_tick()',
  'the service role can still run the tick');

-- No claims at all = pg_cron or a maintenance session.
select set_config('request.jwt.claims', '', true);
select lives_ok('select public.admin_run_tick()',
  'internal callers with no JWT still work (pg_cron)');

-- And the grant itself is gone, so it fails before the body even runs.
select ok(not has_function_privilege('authenticated',
            'public.admin_run_tick()', 'execute'),
  'execute is revoked from authenticated as well');

select * from finish();
rollback;
