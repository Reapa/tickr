-- ============================================================================
-- Migration 26: cosmetics expansion
--
-- A much bigger, more distinctive cosmetic catalog across all four slots, so
-- the store feels worth spending gems (and earning) on. Visual rendering for
-- each code lives client-side in core/cosmetics.dart. Idempotent.
-- ============================================================================
insert into public.cosmetics (code, name, description, slot, rarity, price_premium, is_season_reward) values
  -- Avatar frames -----------------------------------------------------------
  ('frame_silver',   'Silver Frame',      'Clean brushed-steel border.',                         'avatar_frame', 'common',    150,  false),
  ('frame_minimal',  'Hairline Frame',    'A whisper-thin white ring. Understated flex.',        'avatar_frame', 'common',    120,  false),
  ('frame_emerald',  'Emerald Frame',     'Deep green with a jade glow.',                        'avatar_frame', 'rare',      350,  false),
  ('frame_ruby',     'Ruby Frame',        'Molten red for the fearless.',                        'avatar_frame', 'rare',      450,  false),
  ('frame_neon',     'Neon Frame',        'Cyan-and-magenta arcade glow.',                       'avatar_frame', 'rare',      400,  false),
  ('frame_obsidian', 'Obsidian Frame',    'Black glass shot through with violet.',               'avatar_frame', 'epic',      800,  false),
  ('frame_flame',    'Inferno Frame',     'A ring of living fire for the relentless.',           'avatar_frame', 'epic',      900,  false),
  ('frame_holo',     'Holographic Frame', 'Shifts through every colour. Impossible to ignore.',  'avatar_frame', 'epic',      1000, false),
  ('frame_platinum', 'Platinum Frame',    'The quiet luxury of pure platinum.',                  'avatar_frame', 'epic',      1100, false),
  ('frame_champion', 'Champion Frame',    'Crowned gold, awarded to season winners. Not for sale.', 'avatar_frame', 'legendary', null, true),
  -- Profile badges ----------------------------------------------------------
  ('badge_rocket',       'To The Moon',    'Perpetually one candle from lift-off.',              'profile_badge', 'common', 200, false),
  ('badge_moon',         'Moonchild',      'You already live there.',                             'profile_badge', 'common', 200, false),
  ('badge_star',         'Rising Star',    'On the way up.',                                       'profile_badge', 'common', 180, false),
  ('badge_paper_hands',  'Paper Hands',    'Sold the bottom. Wear it proudly.',                   'profile_badge', 'common', 150, false),
  ('badge_fire',         'On Fire',        'A streak nobody wants to end.',                       'profile_badge', 'rare',   300, false),
  ('badge_degen',        'Degen',          'Risk management is a suggestion.',                     'profile_badge', 'rare',   350, false),
  ('badge_brain',        'Galaxy Brain',   'Sees the whole board.',                               'profile_badge', 'rare',   350, false),
  ('badge_shark',        'Shark',          'Smells liquidity from a mile off.',                   'profile_badge', 'rare',   400, false),
  ('badge_diamond_hands','Diamond Hands',  'Never folds. Ever.',                                  'profile_badge', 'rare',   450, false),
  ('badge_goat',         'G.O.A.T.',       'Greatest of all traders.',                            'profile_badge', 'epic',   850, false),
  ('badge_crown',        'Market Royalty', 'Bow to the tape.',                                     'profile_badge', 'epic',   900, false),
  ('badge_founder',      'Founder',        'Here since the opening bell. Cannot be bought.',      'profile_badge', 'legendary', null, true),
  -- Chart themes ------------------------------------------------------------
  ('chart_mono',   'Monochrome Chart',  'Elegant greyscale candles for purists.',              'chart_theme', 'common', 220, false),
  ('chart_matrix', 'Matrix Chart',      'Green-on-black terminal glow.',                       'chart_theme', 'rare',   350, false),
  ('chart_ocean',  'Ocean Chart',       'Cool teal and deep-sea blue.',                        'chart_theme', 'rare',   320, false),
  ('chart_sunset', 'Sunset Chart',      'Warm amber and dusk purple.',                         'chart_theme', 'rare',   320, false),
  -- Ticker skins ------------------------------------------------------------
  ('ticker_mono', 'Mono Ticker',  'Crisp monochrome finances strip.',                          'ticker_skin', 'common', 180, false),
  ('ticker_gold', 'Gold Ticker',  'Your finances bar, gilded.',                                'ticker_skin', 'rare',   350, false),
  ('ticker_neon', 'Neon Ticker',  'Synthwave glow along the bottom.',                          'ticker_skin', 'rare',   350, false)
on conflict (code) do nothing;
