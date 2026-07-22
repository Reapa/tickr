-- ============================================================================
-- Migration 25: more forex pairs (ZAR, CAD, INR)
--
-- These back the new display-currency preference: the app derives each
-- currency's USD conversion from its pair's LIVE simulated price, so switching
-- to Rand shows values at the game's own USD/ZAR rate (and it drifts as that
-- pair trades). Quoted foreign-per-USD like USDJPY. Also tradeable once the
-- forex class is unlocked. Idempotent so it's safe alongside the seed.
-- ============================================================================
insert into public.assets
  (symbol, name, class_id, sector, description,
   current_price, fair_value, drift, base_volatility, liquidity, impact_coef, reversion_speed, spread, market_hours) values
  ('USDZAR', 'Dollar vs Rand',   'forex', 'forex', 'Emerging-market rand: high carry, high drama.', 18.5000, 18.5000, 0.00, 0.14, 300000, 0.012, 0.40, 0.0006, '24_5'),
  ('USDCAD', 'Dollar vs Loonie', 'forex', 'forex', 'Tracks oil and the neighbour up north.',         1.3600,  1.3600, 0.00, 0.09, 500000, 0.010, 0.40, 0.0003, '24_5'),
  ('USDINR', 'Dollar vs Rupee',  'forex', 'forex', 'A managed float with a steady upward drift.',    83.5000, 83.5000, 0.00, 0.10, 350000, 0.012, 0.40, 0.0005, '24_5')
on conflict (symbol) do nothing;
