-- ============================================================================
-- Migration 24: slow the game clock to 7 real days ≈ 6 game months
--
-- seconds_per_game_year sets how much simulated time each tick represents:
-- v_dt = tick_seconds / seconds_per_game_year in game.market_tick(). Drift
-- scales with v_dt (linear) and volatility with sqrt(v_dt). Doubling it from
-- 604800 (7 days = 1 year) to 1209600 (14 days = 1 year) halves per-week drift
-- and cuts price swings ~1.4x, for a calmer, slower-trending market. market_tick
-- reads the value every tick, so no function change is needed.
-- ============================================================================
update public.game_config
   set value = '1209600',
       description = 'Wall-clock seconds representing one game year of drift/'
                     || 'volatility (14 days ⇒ 7 real days ≈ 6 game months).'
 where key = 'seconds_per_game_year';
