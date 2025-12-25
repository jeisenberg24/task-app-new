-- Enable Stripe integration
-- Note: Foreign data wrapper may not be available in all Supabase instances
-- If it fails, customer creation will be handled by Edge Functions instead

-- Try to create foreign data wrapper (will fail gracefully if not available)
do $$
begin
  create extension if not exists wrappers with schema extensions;
exception when others then
  raise notice 'Wrappers extension not available or already exists: %', SQLERRM;
end $$;

-- Attempt to create foreign data wrapper (may fail if Stripe wrapper not available)
do $$
begin
  create foreign data wrapper stripe_wrapper
    handler stripe_fdw_handler
    validator stripe_fdw_validator;
exception when others then
  raise notice 'Stripe foreign data wrapper not available: %. Customer creation will use Edge Functions.', SQLERRM;
end $$;

-- Attempt to create server (only if wrapper was created)
do $$
begin
  create server stripe_server
  foreign data wrapper stripe_wrapper
  options (
    api_key_name 'stripe'
  );
exception when others then
  raise notice 'Stripe server creation skipped (wrapper not available): %', SQLERRM;
end $$;

-- Create schema (this should always work)
create schema if not exists stripe;

-- Attempt to create foreign table (only if server was created)
do $$
begin
  create foreign table stripe.customers (
    id text,
    email text,
    name text,
    description text,
    created timestamp,
    attrs jsonb
  )
  server stripe_server
  options (
    object 'customers',
    rowid_column 'id'
  );
exception when others then
  raise notice 'Stripe foreign table creation skipped (server not available): %', SQLERRM;
end $$;


-- Function to handle Stripe customer creation
-- Note: If foreign data wrapper is not available, this will be a no-op
-- Customer creation will be handled by Edge Functions instead
create or replace function public.handle_stripe_customer_creation()
returns trigger
security definer
set search_path = public
as $$
declare
  customer_email text;
begin
  -- Get user email
  select email into customer_email
  from auth.users
  where id = new.user_id;

  -- Try to create Stripe customer via foreign data wrapper
  -- If foreign table doesn't exist, this will fail gracefully
  begin
    insert into stripe.customers (email, name)
    values (customer_email, new.name);
    
    -- Get the created customer ID from Stripe
    select id into new.stripe_customer_id
    from stripe.customers
    where email = customer_email
    order by created desc
    limit 1;
  exception when others then
    -- Foreign data wrapper not available - customer will be created by Edge Function
    raise notice 'Stripe customer not created via foreign data wrapper (will use Edge Function): %', SQLERRM;
    -- Continue without setting stripe_customer_id - Edge Function will handle it
  end;
  
  return new;
end;
$$ language plpgsql;

-- Trigger to create Stripe customer on profile creation
create trigger create_stripe_customer_on_profile_creation
  before insert on public.profiles
  for each row
  execute function public.handle_stripe_customer_creation();

-- Function to handle Stripe customer deletion
-- Note: If foreign data wrapper is not available, this will be a no-op
-- Customer deletion can be handled by Edge Functions if needed
create or replace function public.handle_stripe_customer_deletion()
returns trigger
security definer
set search_path = public
as $$
begin
  if old.stripe_customer_id is not null then
    begin
      -- Try to delete via foreign data wrapper
      delete from stripe.customers where id = old.stripe_customer_id;
    exception when others then
      -- Foreign data wrapper not available or deletion failed
      -- Continue with profile deletion - customer cleanup can be handled by Edge Functions
      raise notice 'Stripe customer deletion skipped (foreign data wrapper not available or failed): %', SQLERRM;
    end;
  end if;
  return old;
end;
$$ language plpgsql;

-- Trigger to delete Stripe customer on profile deletion
create trigger delete_stripe_customer_on_profile_deletion
  before delete on public.profiles
  for each row
  execute function public.handle_stripe_customer_deletion();

-- Security policy: Users can read their own Stripe data
create policy "Users can read own Stripe data"
  on public.profiles
  for select
  using (auth.uid() = user_id);