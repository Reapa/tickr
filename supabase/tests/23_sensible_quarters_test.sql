-- ============================================================================
-- Sensible news: quarters are valid, and a company's earnings quarter advances
-- Q1→Q2→Q3→Q4→Q1 (never repeating or jumping around).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select plan(6);

select matches(game.current_quarter(), '^Q[1-4]$',
  'current_quarter (news flavour) is Q1-Q4');
select is(game.current_quarter(), game.current_quarter(),
  'current_quarter is consistent at a given moment');

-- Per-company earnings counter maps to an advancing, wrapping quarter.
select is(game.quarter_label(0), 'Q1', 'seq 0 → Q1');
select is(game.quarter_label(3), 'Q4', 'seq 3 → Q4');
select is(game.quarter_label(4), 'Q1', 'seq wraps Q4 → Q1');
select isnt(game.quarter_label(1), game.quarter_label(2),
  'consecutive reports never repeat the same quarter');

select * from finish();
rollback;
