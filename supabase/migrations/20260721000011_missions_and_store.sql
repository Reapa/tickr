-- ============================================================================
-- Migration 11: missions engine (educational layer) + cosmetic store
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Mission evaluation: runs after every trade (from place_market_order).
-- Each mission code has a server-side rule; criteria jsonb parameterizes it.
-- Rewards flow through the transactions ledger.
-- ----------------------------------------------------------------------------
create or replace function game.evaluate_missions(p_user uuid)
returns void
language plpgsql
as $$
declare
  v_um  record;
  v_done boolean;
begin
  for v_um in
    select um.user_id, um.mission_id, m.code, m.criteria, m.reward_cash, m.reward_xp
      from public.user_missions um
      join public.missions m on m.id = um.mission_id
     where um.user_id = p_user and um.status = 'active' and m.is_active
  loop
    v_done := case v_um.code

      when 'first_trade' then
        exists (select 1 from public.trades where user_id = p_user)

      when 'diversify_3' then
        (select count(distinct a.sector)
           from public.holdings h join public.assets a on a.id = h.asset_id
          where h.user_id = p_user)
        >= coalesce((v_um.criteria ->> 'sectors')::int, 3)

      when 'buy_the_dip' then
        -- buy an asset shortly after bad news hit it
        exists (
          select 1
            from public.trades t
            join public.market_events e
              on e.starts_at <= t.created_at
             and t.created_at <= e.starts_at
                   + make_interval(secs => coalesce((v_um.criteria ->> 'window_seconds')::int, 600))
             and e.sentiment = 'negative'
             and (   (e.scope = 'asset' and e.asset_id = t.asset_id)
                  or (e.scope = 'sector' and e.sector =
                        (select sector from public.assets where id = t.asset_id)))
           where t.user_id = p_user and t.side = 'buy')

      when 'earnings_react' then
        -- trade an asset while one of its earnings events is live
        exists (
          select 1
            from public.trades t
            join public.market_events e
              on e.asset_id = t.asset_id
             and e.template_code like 'earnings%'
             and t.created_at between e.starts_at and e.ends_at
           where t.user_id = p_user)

      when 'take_profit' then
        -- sell above your average buy price for that asset
        exists (
          select 1
            from public.trades s
           where s.user_id = p_user and s.side = 'sell'
             and s.price > coalesce((
                   select sum(b.notional) / nullif(sum(b.quantity), 0)
                     from public.trades b
                    where b.user_id = p_user and b.asset_id = s.asset_id
                      and b.side = 'buy' and b.created_at <= s.created_at), 'Infinity'))

      else false
    end;

    if v_done then
      update public.user_missions
         set status = 'completed', completed_at = now()
       where user_id = v_um.user_id and mission_id = v_um.mission_id;

      if v_um.reward_cash > 0 then
        insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
        values (p_user, 'mission_reward', v_um.reward_cash, 'mission', v_um.code);
      end if;
      if v_um.reward_xp > 0 then
        update public.profiles set xp = xp + v_um.reward_xp, updated_at = now()
         where id = p_user;
      end if;
    end if;
  end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Cosmetic store. Premium currency only ever buys cosmetics (see the ledger
-- CHECK constraints); this RPC is the only spend path.
-- ----------------------------------------------------------------------------
create or replace function public.purchase_cosmetic(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user     uuid := auth.uid();
  v_cosmetic public.cosmetics%rowtype;
  v_profile  public.profiles%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  select * into v_cosmetic from public.cosmetics where code = p_code;
  if not found then raise exception 'unknown cosmetic'; end if;
  if v_cosmetic.price_premium is null then
    return jsonb_build_object('status', 'rejected', 'reason', 'not purchasable');
  end if;
  if exists (select 1 from public.user_cosmetics
              where user_id = v_user and cosmetic_id = v_cosmetic.id) then
    return jsonb_build_object('status', 'rejected', 'reason', 'already owned');
  end if;

  select * into v_profile from public.profiles where id = v_user for update;
  if v_profile.premium_balance < v_cosmetic.price_premium then
    return jsonb_build_object('status', 'rejected', 'reason', 'insufficient gems',
                              'required', v_cosmetic.price_premium);
  end if;

  insert into public.premium_ledger (user_id, delta, reason, cosmetic_id)
  values (v_user, -v_cosmetic.price_premium, 'cosmetic_purchase', v_cosmetic.id);

  insert into public.user_cosmetics (user_id, cosmetic_id, acquired_via)
  values (v_user, v_cosmetic.id, 'purchase');

  return jsonb_build_object('status', 'purchased', 'cosmetic', p_code);
end;
$$;

create or replace function public.equip_cosmetic(p_slot text, p_code text)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_cosmetic public.cosmetics%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if p_slot not in ('avatar_frame', 'profile_badge', 'chart_theme', 'ticker_skin') then
    raise exception 'unknown slot';
  end if;

  if p_code is null then
    update public.profiles set equipped = equipped - p_slot, updated_at = now()
     where id = v_user;
    return;
  end if;

  select c.* into v_cosmetic
    from public.cosmetics c
    join public.user_cosmetics uc on uc.cosmetic_id = c.id and uc.user_id = v_user
   where c.code = p_code;
  if not found then raise exception 'cosmetic not owned'; end if;
  if v_cosmetic.slot <> p_slot then raise exception 'cosmetic does not fit that slot'; end if;

  update public.profiles
     set equipped = jsonb_set(equipped, array[p_slot], to_jsonb(p_code)),
         updated_at = now()
   where id = v_user;
end;
$$;

-- ----------------------------------------------------------------------------
-- STORE STUB: stands in for real IAP. Grants a fixed premium package for
-- free so the store flow is testable end-to-end. Replace with server-side
-- receipt validation (App Store / Play Billing / Stripe) before launch —
-- keep the same reason ('iap_stub' -> 'iap') so history stays auditable.
-- ----------------------------------------------------------------------------
create or replace function public.stub_purchase_premium(p_package text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user   uuid := auth.uid();
  v_amount int;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  v_amount := case p_package
    when 'small'  then 100
    when 'medium' then 550
    when 'large'  then 1200
    else null end;
  if v_amount is null then raise exception 'unknown package'; end if;

  insert into public.premium_ledger (user_id, delta, reason)
  values (v_user, v_amount, 'iap_stub');

  return jsonb_build_object('status', 'granted', 'amount', v_amount,
                            'note', 'stub purchase - no real payment in v1');
end;
$$;

grant execute on function public.purchase_cosmetic(text) to authenticated;
grant execute on function public.equip_cosmetic(text, text) to authenticated;
grant execute on function public.stub_purchase_premium(text) to authenticated;
