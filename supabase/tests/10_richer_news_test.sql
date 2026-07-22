-- ============================================================================
-- Richer news generation. The market_tick advisory lock is held so the live
-- cron tick can't spawn competing events mid-test.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';
-- Never draw from the major pool in this test (we prune to one normal template).
update public.game_config set value = '0' where key = 'major_event_share';

select plan(4);

-- The token renderer.
select is(game.render_template('{a}/{b}', '{"a":"X","b":"Y"}'::jsonb), 'X/Y',
  'render_template substitutes {tokens}');
select is(game.render_template('plain text', '{}'::jsonb), 'plain text',
  'render_template leaves untokenised text untouched');

-- Pin the pool to a single positive template so the spawn is deterministic,
-- then confirm the body gained a positive detail sentence. (Clear existing
-- events first so pruning the templates doesn't trip the FK.)
delete from public.market_events;
delete from public.event_templates where code <> 'earnings_beat';
update public.assets set current_price = 100.00 where symbol = 'GOGL';
select game.spawn_market_event();

select is(
  (select sentiment from public.market_events order by starts_at desc limit 1),
  'positive', 'an earnings beat spawns a positive event');
select ok(
  (select body from public.market_events order by starts_at desc limit 1)
    ~ 'target|momentum|added value|re-rating|Call buying',
  'the body carries a randomised positive detail sentence');

select * from finish();
rollback;
