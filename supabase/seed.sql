-- ============================================================================
-- Seed data: makes the game playable immediately after `supabase db reset`.
-- All names are fictional — no real companies, no real market data.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Asset classes (the progression ladder)
-- ----------------------------------------------------------------------------
insert into public.asset_classes (id, name, description, unlock_cost, is_enabled, sort_order) values
  ('stocks',      'Stocks',      'Shares in fictional companies across five sectors. Free to trade from day one.', 0, true, 1),
  ('real_estate', 'Real Estate', 'Property funds: slower-moving, steadier income-style assets. Buy your way in.', 50000, true, 2),
  ('companies',   'Companies',   'Own entire private companies. Coming soon.', 250000, false, 3),
  ('margin',      'Broker License', 'Trade with leverage: control 5-100x your stake, long or short. High risk, high reward — you can lose your whole margin.', 25000, true, 4),
  ('crypto',      'Crypto',      'The 24/7 casino: wildly volatile coins that never stop trading. Weekends belong to crypto.', 2500, true, 5),
  ('forex',       'Forex',       'Currency pairs: tiny moves, huge liquidity, open 24/5. Where leverage earns its keep.', 10000, true, 6);

-- ----------------------------------------------------------------------------
-- Stocks: 16 across 5 sectors. Volatility/liquidity tuned per personality:
-- tech runs hot, utilities sleep, small caps whip around on thin liquidity.
-- ----------------------------------------------------------------------------
-- Names are parodies of familiar companies — recognizable, but fictional.
insert into public.assets
  (symbol, name, class_id, sector, description,
   current_price, fair_value, drift, base_volatility, liquidity, impact_coef, reversion_speed, spread) values
  -- tech
  ('GOGL', 'Googol',              'stocks', 'tech', 'Search, ads, and a graveyard of side projects.',            182.50, 182.50, 0.09, 0.45, 160000, 0.05, 0.25, 0.0020),
  ('ENVD', 'Envidia',             'stocks', 'tech', 'Everyone needs their chips. Everyone. All at once.',         64.20,  64.20, 0.12, 0.70,  60000, 0.08, 0.20, 0.0040),
  ('NTDO', 'Nintendont',          'stocks', 'tech', 'Beloved game maker; one plumber carries the company.',       28.75,  28.75, 0.07, 0.55,  50000, 0.07, 0.25, 0.0035),
  ('AMZM', 'Amazoom',             'stocks', 'tech', 'Sells everything, delivers yesterday.',                      41.10,  41.10, 0.08, 0.50,  70000, 0.06, 0.25, 0.0030),
  -- energy
  ('SLCT', 'SolCity Energy',      'stocks', 'energy', 'Solar roofs and giant batteries.',                         55.40,  55.40, 0.06, 0.35, 100000, 0.05, 0.25, 0.0025),
  ('TSLR', 'Tesler Motors',       'stocks', 'energy', 'Electric cars. The CEO tweets a lot.',                     33.80,  33.80, 0.05, 0.40,  56000, 0.06, 0.25, 0.0030),
  ('XOFF', 'Exxoff Mobil',        'stocks', 'energy', 'Old-school oil major, big dividends, slow decline.',       88.90,  88.90, 0.03, 0.30, 180000, 0.04, 0.30, 0.0018),
  -- finance
  ('GMSX', 'Goldmine Sacks',      'stocks', 'finance', 'The bank other banks call when scared.',                 112.30, 112.30, 0.05, 0.25, 240000, 0.03, 0.30, 0.0015),
  ('VIZA', 'Viza',                'stocks', 'finance', 'Takes a tiny cut of everything you buy.',                  74.60,  74.60, 0.10, 0.50,  80000, 0.06, 0.22, 0.0030),
  ('GEKO', 'Geckco Insurance',    'stocks', 'finance', 'Fifteen minutes could save you fifteen dollars.',          47.20,  47.20, 0.04, 0.28, 120000, 0.04, 0.30, 0.0020),
  -- consumer
  ('SBRW', 'Starbrews Coffee',    'stocks', 'consumer', 'A coffee shop inside every coffee shop.',                36.50,  36.50, 0.07, 0.35,  90000, 0.05, 0.28, 0.0025),
  ('KOKA', 'Koka-Kola',           'stocks', 'consumer', 'Fizzy sugar water; unstoppable for a century.',          61.80,  61.80, 0.05, 0.22, 200000, 0.03, 0.30, 0.0015),
  ('NIKY', 'Nikey',               'stocks', 'consumer', 'Just did it. Sneaker hype cycles included.',              94.40,  94.40, 0.06, 0.45,  70000, 0.06, 0.22, 0.0035),
  -- healthcare
  ('MDNA', 'Modernia Labs',       'stocks', 'healthcare', 'Biotech moonshots; binary trial outcomes.',            52.70,  52.70, 0.09, 0.65,  52000, 0.08, 0.20, 0.0040),
  ('JNJN', 'Jonson & Jonson',     'stocks', 'healthcare', 'Band-aids to baby shampoo, and lawyers.',               77.90,  77.90, 0.06, 0.32, 110000, 0.04, 0.28, 0.0022),
  ('PFZR', 'Pfazer',              'stocks', 'healthcare', 'Diversified pharma with a steady pipeline.',           103.60, 103.60, 0.05, 0.28, 160000, 0.04, 0.30, 0.0018);

-- ----------------------------------------------------------------------------
-- Real estate: unlockable tier — lower volatility, higher prices, thinner books.
-- ----------------------------------------------------------------------------
insert into public.assets
  (symbol, name, class_id, sector, description,
   current_price, fair_value, drift, base_volatility, liquidity, impact_coef, reversion_speed, spread) values
  ('DWTN', 'Downtown Towers REIT',  'real_estate', 'commercial',  'Prime office towers in the capital.',      1250.00, 1250.00, 0.05, 0.15, 400000, 0.03, 0.15, 0.0050),
  ('SUBH', 'Suburbia Homes Fund',   'real_estate', 'residential', 'Single-family rental portfolio.',           640.00,  640.00, 0.06, 0.12, 300000, 0.03, 0.15, 0.0045),
  ('MALL', 'Grand Mall Holdings',   'real_estate', 'commercial',  'Shopping malls betting on a comeback.',     310.00,  310.00, 0.03, 0.25, 160000, 0.05, 0.18, 0.0060),
  ('WRHS', 'Warehouse Logistics Trust', 'real_estate', 'industrial', 'Fulfillment centers on every highway.',  920.00,  920.00, 0.07, 0.18, 360000, 0.03, 0.15, 0.0045),
  ('ISLE', 'Island Resorts Group',  'real_estate', 'hospitality', 'Beach resorts; sunny until a storm hits.',  480.00,  480.00, 0.06, 0.30, 120000, 0.06, 0.18, 0.0070);

-- ----------------------------------------------------------------------------
-- Companies: scaffolded third tier (class disabled; assets inactive).
-- ----------------------------------------------------------------------------
insert into public.assets
  (symbol, name, class_id, sector, description,
   current_price, fair_value, drift, base_volatility, liquidity, impact_coef, reversion_speed, spread, is_active) values
  ('CO-CAI',  'ClosedAI Labs',       'companies', 'private', 'A secretive AI lab. Definitely nothing to worry about.', 50000.00, 50000.00, 0.08, 0.20, 1000000, 0.02, 0.10, 0.0100, false),
  ('CO-SPCY', 'SpaceY',              'companies', 'private', 'Reusable rockets. They land, usually on purpose.',       85000.00, 85000.00, 0.10, 0.30, 1000000, 0.02, 0.10, 0.0100, false),
  ('CO-TED',  'The Tedious Company', 'companies', 'private', 'Digs tunnels. Very slowly. Very expensively.',          120000.00,120000.00, 0.06, 0.18, 1000000, 0.02, 0.10, 0.0100, false);

-- ----------------------------------------------------------------------------
-- Crypto: 24/7, extreme volatility, thin books. For the courageous.
-- ----------------------------------------------------------------------------
insert into public.assets
  (symbol, name, class_id, sector, description,
   current_price, fair_value, drift, base_volatility, liquidity, impact_coef, reversion_speed, spread, market_hours) values
  ('BTCN', 'Bitcorn',   'crypto', 'crypto', 'Digital gold, allegedly. Never sleeps.',                 67500.00, 67500.00, 0.10, 1.20, 400000, 0.05, 0.20, 0.0010, '24_7'),
  ('ETHR', 'Ethereal',  'crypto', 'crypto', 'Programmable money and expensive digital art.',            3520.00,  3520.00, 0.10, 1.50, 160000, 0.06, 0.20, 0.0015, '24_7'),
  ('SOLM', 'Solami',    'crypto', 'crypto', 'Very fast. Occasionally very offline.',                     152.00,   152.00, 0.12, 1.80,  60000, 0.08, 0.20, 0.0025, '24_7'),
  ('DOGR', 'Dogercoin', 'crypto', 'crypto', 'A joke that refuses to die. Much volatile. Wow.',             0.1250,   0.1250, 0.00, 2.50,   8000, 0.10, 0.15, 0.0050, '24_7');

-- ----------------------------------------------------------------------------
-- Forex: 24/5, tiny moves, deep liquidity — leverage country.
-- ----------------------------------------------------------------------------
insert into public.assets
  (symbol, name, class_id, sector, description,
   current_price, fair_value, drift, base_volatility, liquidity, impact_coef, reversion_speed, spread, market_hours) values
  ('EURUSD', 'Euro vs Dollar',   'forex', 'forex', 'The world''s most traded pair.',            1.0850, 1.0850, 0.00, 0.08, 800000, 0.010, 0.40, 0.0002, '24_5'),
  ('GBPUSD', 'Pound vs Dollar',  'forex', 'forex', 'Cable: prone to political drama.',          1.2700, 1.2700, 0.00, 0.10, 600000, 0.010, 0.40, 0.0002, '24_5'),
  ('USDJPY', 'Dollar vs Yen',    'forex', 'forex', 'The carry-trade classic.',                148.5000,148.5000, 0.00, 0.09, 700000, 0.010, 0.40, 0.0002, '24_5'),
  ('AUDUSD', 'Aussie vs Dollar', 'forex', 'forex', 'Rides commodity booms and busts.',          0.6550, 0.6550, 0.00, 0.11, 400000, 0.015, 0.40, 0.0003, '24_5');

-- ----------------------------------------------------------------------------
-- Event templates: the news generator. Weights skew toward mild sector/asset
-- news; big macro shocks are rare. Durations = how long volatility stays high.
-- ----------------------------------------------------------------------------
insert into public.event_templates
  (code, scope, headline_template, body_template, fv_impact_min, fv_impact_max, vol_multiplier, duration_seconds, weight, class_id) values
  ('earnings_beat',  'asset',  '{name} crushes earnings expectations',
   '{symbol} reported quarterly profits well above forecasts. Analysts scramble to raise targets.',
   0.04, 0.12, 1.8, 900, 3, 'stocks'),
  ('earnings_miss',  'asset',  '{name} misses earnings badly',
   '{symbol} fell short of profit expectations this quarter. Guidance was cut for the rest of the year.',
   -0.12, -0.04, 1.8, 900, 3, 'stocks'),
  ('product_launch', 'asset',  '{name} unveils surprise new product',
   'A splashy launch event has customers lining up and competitors worried.',
   0.03, 0.10, 1.5, 700, 2, 'stocks'),
  ('scandal',        'asset',  'Scandal rocks {name}',
   'Reports of accounting irregularities at {symbol} send investors for the exits.',
   -0.18, -0.08, 2.2, 1200, 1, 'stocks'),
  ('analyst_upgrade','asset',  'Analysts turn bullish on {name}',
   'A wave of upgrades cites improving fundamentals at {symbol}.',
   0.02, 0.06, 1.2, 500, 3, null),
  ('analyst_downgrade','asset','Analysts sour on {name}',
   'Several banks cut their ratings on {symbol}, citing stretched valuation.',
   -0.06, -0.02, 1.2, 500, 3, null),
  ('sector_boom',    'sector', '{sector} sector surges on strong demand',
   'Demand across the {sector} sector is running hotter than anyone forecast.',
   0.03, 0.08, 1.4, 900, 2, null),
  ('sector_slump',   'sector', '{sector} sector hit by slowdown fears',
   'Weak data points to a rough quarter ahead for the {sector} sector.',
   -0.08, -0.03, 1.4, 900, 2, null),
  ('regulation',     'sector', 'Regulators take aim at {sector}',
   'Sweeping new rules proposed for the {sector} sector could squeeze margins.',
   -0.10, -0.04, 1.6, 1100, 1, null),
  ('rate_cut',       'market', 'Central bank surprises with rate cut',
   'Cheaper money lifts almost everything. Traders celebrate.',
   0.02, 0.05, 1.3, 1200, 1, null),
  ('rate_hike',      'market', 'Central bank hikes rates to fight inflation',
   'Borrowing just got more expensive. Markets wobble across the board.',
   -0.05, -0.02, 1.3, 1200, 1, null),
  ('market_panic',   'market', 'Flash panic grips the market',
   'A wave of selling hits every sector at once. Cool heads hunt for bargains.',
   -0.09, -0.04, 2.0, 1500, 0.5, null),
  ('property_boom',  'sector', 'Property values jump in {sector} real estate',
   'A hot property market lifts {sector} portfolios.',
   0.02, 0.06, 1.3, 1200, 1, 'real_estate'),
  ('storm_damage',   'asset',  'Storm damage hits {name}',
   'A severe storm damaged properties held by {symbol}. Repair costs loom.',
   -0.10, -0.04, 1.8, 1400, 0.8, 'real_estate'),
  ('crypto_pump',    'asset',  '{name} goes parabolic',
   'ETF rumors, moon math, and pure momentum send {symbol} vertical.',
   0.08, 0.30, 2.2, 900, 1.5, 'crypto'),
  ('crypto_dump',    'asset',  'Whale dumps {name}',
   'A single wallet just moved a fortune in {symbol} onto an exchange. It sold.',
   -0.30, -0.10, 2.5, 900, 1.5, 'crypto'),
  ('crypto_regs',    'sector', 'Regulators take aim at crypto',
   'New rules proposed for digital assets. The market does not love rules.',
   -0.15, -0.05, 1.8, 1200, 0.8, 'crypto'),
  ('rate_decision',  'sector', 'Central banks jolt currency markets',
   'A surprise rate decision ripples through the major pairs.',
   -0.02, 0.02, 1.6, 1200, 1, 'forex');

-- ----------------------------------------------------------------------------
-- Missions: the educational layer. Each teaches one concept by doing.
-- ----------------------------------------------------------------------------
insert into public.missions (code, title, description, concept, reward_cash, reward_xp, criteria, sort_order) values
  ('first_trade',   'Make Your First Trade',
   'Buy any stock. You learn markets by being in them — start small.',
   'basics', 250, 50, '{}', 1),
  ('diversify_3',   'Don''t Keep All Eggs in One Basket',
   'Hold assets in 3 different sectors at the same time. When one sector slumps, the others cushion the blow — that''s diversification.',
   'diversification', 500, 100, '{"sectors": 3}', 2),
  ('buy_the_dip',   'Buy the Dip',
   'Buy an asset within 10 minutes of bad news hitting it. Prices often overreact to news and then recover toward fair value — that''s mean reversion.',
   'mean_reversion', 750, 150, '{"window_seconds": 600}', 3),
  ('earnings_react','Trade the News',
   'Trade a stock while an earnings event is live. Earnings are when prices move most — news moves markets.',
   'news_reaction', 500, 100, '{}', 4),
  ('take_profit',   'Lock In a Win',
   'Sell an asset for more than your average buy price. A profit isn''t real until you take it.',
   'basics', 500, 100, '{}', 5),
  ('set_stop_loss', 'Set a Safety Net',
   'Protect a position with a stop loss. Deciding your maximum loss before it happens is what separates traders from gamblers.',
   'risk', 500, 100, '{}', 6),
  ('use_leverage',  'Play With Fire',
   'Open a leveraged position. Leverage multiplies gains AND losses — respect the liquidation price.',
   'risk', 500, 100, '{}', 7);

-- ----------------------------------------------------------------------------
-- Cosmetics: strictly visual. price_premium NULL = season-reward only.
-- ----------------------------------------------------------------------------
insert into public.cosmetics (code, name, description, slot, rarity, price_premium, is_season_reward) values
  ('frame_bronze',   'Bronze Frame',        'A modest bronze border for your avatar.',        'avatar_frame', 'common',    100, false),
  ('frame_gold',     'Gold Frame',          'Flex a golden border on the leaderboard.',       'avatar_frame', 'rare',      400, false),
  ('frame_diamond',  'Diamond Frame',       'For traders with expensive taste.',              'avatar_frame', 'epic',      900, false),
  ('badge_bull',     'Bull Badge',          'Permanently optimistic.',                        'profile_badge','common',    150, false),
  ('badge_bear',     'Bear Badge',          'Professionally pessimistic.',                    'profile_badge','common',    150, false),
  ('badge_whale',    'Whale Badge',         'Moves markets when they sneeze.',                'profile_badge','epic',      800, false),
  ('chart_neon',     'Neon Chart Theme',    'Trade like it''s a cyberpunk arcade.',           'chart_theme',  'rare',      300, false),
  ('chart_paper',    'Newspaper Chart Theme','Charts styled like an old broadsheet.',         'chart_theme',  'rare',      300, false),
  ('ticker_retro',   'Retro Ticker Skin',   'Green phosphor glow, like the old days.',        'ticker_skin',  'common',    200, false),
  ('frame_season_1', 'Season 1 Champion Frame', 'Awarded to Season 1 top finishers. Cannot be bought.', 'avatar_frame', 'legendary', null, true);

-- ----------------------------------------------------------------------------
-- Season 1 starts now.
-- ----------------------------------------------------------------------------
insert into public.seasons (number, name, starts_at, ends_at, reward_cosmetic_code)
values (1, 'Season 1: Opening Bell', now(),
        now() + make_interval(days => (select (value #>> '{}')::int from public.game_config where key = 'season_length_days')),
        'frame_season_1');
