-- ============================================================================
-- Migration 7: new-player onboarding
--
-- A trigger on auth.users creates the profile, grants starting cash (through
-- the ledger, like all money), grants the free "stocks" unlock and welcome
-- premium currency, enrolls seed missions, and joins the active season.
-- ============================================================================

create or replace function game.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_name    text;
  v_code    text;
  v_cash    numeric := game.config_numeric('starting_cash');
  v_premium int     := game.config_numeric('starting_premium')::int;
  v_season  public.seasons%rowtype;
begin
  -- Display name: explicit metadata > OAuth full name > email local part.
  v_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    split_part(coalesce(new.email, 'trader'), '@', 1)
  );
  v_name := left(v_name, 20);
  if char_length(v_name) < 2 then
    v_name := 'Trader';
  end if;

  -- De-duplicate display names and retry friend-code collisions.
  if exists (select 1 from public.profiles where lower(display_name) = lower(v_name)) then
    v_name := left(v_name, 14) || '-' || substr(md5(new.id::text), 1, 4);
  end if;
  loop
    v_code := game.generate_friend_code();
    exit when not exists (select 1 from public.profiles where friend_code = v_code);
  end loop;

  insert into public.profiles (id, display_name, friend_code)
  values (new.id, v_name, v_code);

  -- Starting cash flows through the ledger so it reconciles like everything else.
  insert into public.transactions (user_id, type, cash_delta, ref_type)
  values (new.id, 'starting_grant', v_cash, 'onboarding');

  insert into public.premium_ledger (user_id, delta, reason)
  values (new.id, v_premium, 'welcome_grant');

  -- Stocks are the free tier.
  insert into public.user_asset_class_unlocks (user_id, class_id)
  values (new.id, 'stocks');

  -- Enroll all active missions.
  insert into public.user_missions (user_id, mission_id)
  select new.id, m.id from public.missions m where m.is_active;

  -- Join the running season with net worth = starting cash.
  select * into v_season
    from public.seasons
   where status = 'active' and now() between starts_at and ends_at
   order by number desc limit 1;
  if found then
    insert into public.season_scores
      (season_id, user_id, starting_net_worth, current_net_worth)
    values (v_season.id, new.id, v_cash, v_cash);
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function game.handle_new_user();

-- ----------------------------------------------------------------------------
-- Profile self-service RPCs (the only way clients change their profile).
-- ----------------------------------------------------------------------------
create or replace function public.update_display_name(p_name text)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_name is null or char_length(trim(p_name)) not between 2 and 24 then
    raise exception 'display name must be 2-24 characters';
  end if;
  if exists (select 1 from public.profiles
              where lower(display_name) = lower(trim(p_name)) and id <> auth.uid()) then
    raise exception 'display name already taken';
  end if;
  update public.profiles
     set display_name = trim(p_name), updated_at = now()
   where id = auth.uid();
end;
$$;

grant execute on function public.update_display_name(text) to authenticated;
