-- ============================================================================
-- Daily streak tests: claim, escalation, reset on a gap, weekly milestone,
-- and ledger reconciliation. Dates are manipulated directly to simulate days.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select plan(13);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'authenticated', 'authenticated', 'alice@example.test',
        '{"display_name": "Alice"}'::jsonb);

select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);

create temp table r (label text primary key, receipt jsonb);

-- Day 1 claim.
insert into r values ('d1', claim_daily_reward());
select is(receipt ->> 'status', 'claimed', 'first claim succeeds') from r where label = 'd1';
select is((receipt ->> 'streak')::int, 1, 'streak starts at 1') from r where label = 'd1';
select is((receipt ->> 'reward')::numeric, 200::numeric, 'day 1 pays 200') from r where label = 'd1';
select is(cash_balance, 10200.00::numeric(18,2), 'reward credited through the ledger')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

-- Same day again: no double dip.
insert into r values ('again', claim_daily_reward());
select is(receipt ->> 'status', 'already_claimed', 'cannot claim twice in a day')
  from r where label = 'again';

-- Simulate: last claim was yesterday, streak 1 -> consecutive day continues.
update profiles set last_claim_date = (now() at time zone 'utc')::date - 1, streak_days = 1
 where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
insert into r values ('d2', claim_daily_reward());
select is((receipt ->> 'streak')::int, 2, 'consecutive day increments the streak')
  from r where label = 'd2';
select is((receipt ->> 'reward')::numeric, 300::numeric, 'day 2 pays 300') from r where label = 'd2';

-- Simulate a gap (last claim 3 days ago): streak resets.
update profiles set last_claim_date = (now() at time zone 'utc')::date - 3, streak_days = 9
 where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
insert into r values ('gap', claim_daily_reward());
select is((receipt ->> 'streak')::int, 1, 'a missed day resets the streak')
  from r where label = 'gap';
select is((receipt ->> 'reward')::numeric, 200::numeric, 'reset day pays 200') from r where label = 'gap';

-- Weekly milestone: day 7 pays the escalating amount + 1000 bonus.
update profiles set last_claim_date = (now() at time zone 'utc')::date - 1, streak_days = 6
 where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
insert into r values ('milestone', claim_daily_reward());
select is((receipt ->> 'streak')::int, 7, 'day 7 reached') from r where label = 'milestone';
select is(receipt ->> 'milestone', 'true', 'day 7 flagged as a milestone')
  from r where label = 'milestone';
select is((receipt ->> 'reward')::numeric, 1800::numeric,
  'day 7 pays 800 escalating + 1000 milestone') from r where label = 'milestone';

select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger reconciles after streak rewards');

select * from finish();
rollback;
