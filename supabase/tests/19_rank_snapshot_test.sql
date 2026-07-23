-- ============================================================================
-- Rank snapshot: caller's global rank + the name one place below.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
select plan(3);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1',
        'authenticated', 'authenticated', 'hank@example.test',
        '{"display_name": "Hank"}'::jsonb),
       ('00000000-0000-0000-0000-000000000000',
        'c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2',
        'authenticated', 'authenticated', 'iris@example.test',
        '{"display_name": "Iris"}'::jsonb);

-- Hank ahead of Iris on net worth.
update public.profiles set net_worth = 999999
 where id = 'c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1';
update public.profiles set net_worth = 888888
 where id = 'c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2';

-- As Hank: rank 1, with Iris one place below.
select set_config('request.jwt.claims',
  '{"sub": "c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1", "role": "authenticated"}', true);
select is((public.my_rank_snapshot() ->> 'rank')::int, 1, 'top net worth ranks #1');
select is(public.my_rank_snapshot() ->> 'ahead_of', 'Iris',
  'the snapshot names who is one place below');

-- As Iris: ranked below Hank.
select set_config('request.jwt.claims',
  '{"sub": "c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2", "role": "authenticated"}', true);
select ok((public.my_rank_snapshot() ->> 'rank')::int >= 2,
  'a lower net worth ranks below the leader');

select * from finish();
rollback;
