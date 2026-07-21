-- ============================================================================
-- Competition tests: friend graph, head-to-head challenges, season rollover.
-- Deterministic because neither player holds assets — net worth == cash.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

-- Serialize against the live pg_cron tick: hold the tick's advisory lock
-- for this whole transaction so in-test ticks always run and background
-- ticks no-op instead of blocking on our pinned rows.
select pg_advisory_xact_lock(hashtext('game.market_tick'));

select plan(22);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000000', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'authenticated', 'authenticated', 'alice@example.test', '{"display_name": "Alice"}'::jsonb),
  ('00000000-0000-0000-0000-000000000000', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   'authenticated', 'authenticated', 'bob@example.test', '{"display_name": "Bob"}'::jsonb);

-- Hermetic: seasons rank EVERY profile, so remove any other players the dev
-- database has accumulated (all rolled back with this transaction). The
-- append-only ledger guards rightly block cascade deletes, so suspend them
-- for the purge only.
alter table public.transactions disable trigger transactions_append_only;
alter table public.premium_ledger disable trigger premium_ledger_append_only;
delete from auth.users
 where id not in ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
alter table public.transactions enable trigger transactions_append_only;
alter table public.premium_ledger enable trigger premium_ledger_append_only;

-- Tick once so net_worth is populated (challenges snapshot it).
select game.market_tick();

create temp table r (label text primary key, receipt jsonb);

-- ---------------------------------------------------------------------------
-- Friends via friend codes.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);

insert into r values ('nocode', send_friend_request('TG-NOPE99'));
select is(receipt ->> 'reason', 'no player with that friend code', 'unknown codes rejected')
  from r where label = 'nocode';

insert into r values ('selfcode', send_friend_request(
  (select friend_code from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')));
select is(receipt ->> 'reason', 'that is your own code', 'cannot befriend yourself')
  from r where label = 'selfcode';

insert into r values ('req', send_friend_request(
  (select friend_code from profiles where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')));
select is(receipt ->> 'status', 'pending', 'friend request created') from r where label = 'req';

-- Bob sending back = mutual accept.
select set_config('request.jwt.claims',
  '{"sub": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "role": "authenticated"}', true);
insert into r values ('mutual', send_friend_request(
  (select friend_code from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')));
select is(receipt ->> 'status', 'accepted', 'reciprocal request auto-accepts')
  from r where label = 'mutual';
select ok(game.are_friends('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                           'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'), 'friendship recorded');

-- ---------------------------------------------------------------------------
-- Challenge lifecycle.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);
insert into r values ('ch', create_friend_challenge('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '24h'));
select is(receipt ->> 'status', 'pending', 'challenge issued') from r where label = 'ch';

insert into r values ('dup', create_friend_challenge('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '7d'));
select is(receipt ->> 'reason', 'an open challenge with this friend already exists',
  'one open challenge per pair') from r where label = 'dup';

select set_config('request.jwt.claims',
  '{"sub": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "role": "authenticated"}', true);
insert into r values ('accept', respond_friend_challenge(
  ((select receipt ->> 'challenge_id' from r where label = 'ch'))::uuid, true));
select is(receipt ->> 'status', 'active', 'challenge accepted') from r where label = 'accept';
select ok(challenger_start_nw = 10000.00 and challengee_start_nw = 10000.00,
  'net worths snapshotted at accept')
  from friend_challenges where status = 'active';

-- Alice outperforms; window ends; tick resolves.
insert into transactions (user_id, type, cash_delta, ref_type, ref_id)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'mission_reward', 5500, 'mission', 'test-perf');
update friend_challenges set ends_at = now() - interval '1 second' where status = 'active';

select game.market_tick();

select is(status, 'completed', 'due challenge resolved by tick') from friend_challenges limit 1;
select is(winner_id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid, 'higher %% return wins')
  from friend_challenges limit 1;
select is(challenger_return, 0.55::numeric(12,6), 'challenger return = 15500/10000 - 1')
  from friend_challenges limit 1;
select is(challengee_return, 0::numeric(12,6), 'challengee return = 0')
  from friend_challenges limit 1;
select is(count(*)::int, 1, 'winner paid through the ledger')
  from transactions where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and type = 'challenge_reward' and cash_delta = 500;

-- ---------------------------------------------------------------------------
-- Season rollover: close, rank, reward, reopen.
-- ---------------------------------------------------------------------------
update seasons set ends_at = now() - interval '1 second' where number = 1;
select game.market_tick();

select is(status, 'closed', 'ended season closed') from seasons where number = 1;
select is(count(*)::int, 1, 'next season opened automatically')
  from seasons where number = 2 and status = 'active';
select is(final_rank, 1, 'winner ranked first')
  from season_scores where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and season_id = (select id from seasons where number = 1);
select is(count(*)::int, 1, 'champion cosmetic granted to top finisher')
  from user_cosmetics uc join cosmetics c on c.id = uc.cosmetic_id
 where uc.user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and c.code = 'frame_season_1' and uc.acquired_via = 'season_reward';
select is(premium_balance, 300, 'season premium bonus: 200 welcome + 100')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(cash_balance, 21000.00::numeric(18,2),
  'alice cash: 10000 + 5500 + 500 challenge + 5000 season prize')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(cash_balance, 12500.00::numeric(18,2), 'bob cash: 10000 + 2500 runner-up prize')
  from profiles where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger reconciles after competition payouts');

select * from finish();
rollback;
