-- ============================================================================
-- Net-worth milestone ladder: lazy claim, idempotency, crate + XP rewards.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
select plan(7);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        'authenticated', 'authenticated', 'erin@example.test',
        '{"display_name": "Erin"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "role": "authenticated"}', true);

create temp table cr (label text primary key, receipt jsonb);

-- Starting net worth ($10k) is below the first rung ($15k).
insert into cr values ('none', public.claim_milestones());
select is(jsonb_array_length(receipt -> 'newly_reached'), 0,
  'nothing to claim below the first milestone') from cr where label = 'none';

-- Cross to $25k: reaches the $15k and $20k rungs.
update public.profiles set net_worth = 25000
 where id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
insert into cr values ('c1', public.claim_milestones());
select is(jsonb_array_length(receipt -> 'newly_reached'), 2,
  'two milestones reached at $25k') from cr where label = 'c1';
select is((select count(*)::int from public.user_crates
            where user_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' and source = 'milestone'),
  2, 'each milestone drops a crate');
select is((select xp from public.profiles
            where id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'),
  250, 'milestone XP granted (100 + 150)');

-- Claiming again at the same net worth is a no-op.
insert into cr values ('again', public.claim_milestones());
select is(jsonb_array_length(receipt -> 'newly_reached'), 0,
  'claiming again reaches nothing new') from cr where label = 'again';

-- Cross to $60k: reaches the $30k and $50k rungs.
update public.profiles set net_worth = 60000
 where id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
insert into cr values ('c2', public.claim_milestones());
select is(jsonb_array_length(receipt -> 'newly_reached'), 2,
  'two more milestones reached at $60k') from cr where label = 'c2';
select is((select count(*)::int from public.user_milestones
            where user_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'),
  4, 'four milestones recorded in total');

select * from finish();
rollback;
