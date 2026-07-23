-- ============================================================================
-- Companies Phase 2: a decision is posted, answering it grows the company
-- (bounded) and charges the option cost, and an ignored one expires.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
select plan(8);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        'authenticated', 'authenticated', 'cara@example.test',
        '{"display_name": "Cara"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "role": "authenticated"}', true);

insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'mission_reward', 200000, 'test');
insert into public.user_asset_class_unlocks (user_id, class_id)
values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'companies');

create temp table cr (label text primary key, receipt jsonb);
insert into cr values ('found', public.found_company('Widgets', 'software', 60000));

-- Force determinism: only the 'grow' reinvest template can be posted.
delete from public.company_decision_templates where id <> 'grow';

-- Make the company due and post a decision.
update public.user_companies set next_decision_at = now() - interval '1 minute'
 where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
select game.post_company_decisions();

select is((select count(*)::int from public.company_decisions
            where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' and status = 'pending'),
  1, 'a pending decision is posted for a due company');
select is((select template_id from public.company_decisions
            where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' limit 1),
  'grow', 'the posted decision uses the grow template');

-- Answer with "marketing": cost = 0.6 * 60000 * 0.05 = 1800; revenue grows.
insert into cr
  select 'decide', public.make_company_decision(d.id, 'marketing')
    from public.company_decisions d
   where d.user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' and d.status = 'pending';
select is(cr.receipt ->> 'status', 'ok', 'the decision resolves ok')
  from cr where label = 'decide';
select is((select cash_balance from public.profiles
            where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  148200.00::numeric, 'the option cost is charged (150000 - 1800)');
select is((select invested_basis from public.user_companies
            where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  61800.00::numeric, 'invested capital rises by the cost (raising the growth cap)');
select ok((select revenue_rate from public.user_companies
            where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc') > 2727.27,
  'marketing raises revenue above the starting rate');
select is((select status from public.company_decisions
            where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' and template_id = 'grow'
            order by opens_at limit 1),
  'resolved', 'the answered decision is marked resolved');

-- Ignore the next one: it expires (grow has no default → no change, clock advances).
update public.user_companies set next_decision_at = now() - interval '1 minute'
 where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
select game.post_company_decisions();
update public.company_decisions set expires_at = now() - interval '1 minute'
 where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' and status = 'pending';
select game.post_company_decisions();
select is((select count(*)::int from public.company_decisions
            where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' and status = 'expired'),
  1, 'an unanswered decision expires');

select * from finish();
rollback;
