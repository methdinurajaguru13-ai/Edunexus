-- ===================================================================
-- EduNexus: profile picture borders + an admin "unlock everything" flag.
-- Run once in the Supabase SQL Editor. Safe to run twice.
-- ===================================================================

alter table public.profiles add column if not exists border     text    not null default 'classic';
alter table public.profiles add column if not exists unlock_all boolean not null default false;

-- Users can edit their own profile, so without this anyone could grant
-- themselves everything. Signed-in users can never set or change unlock_all;
-- only the SQL Editor or the service role can.
create or replace function public.protect_unlock_all()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.unlock_all := false;
    elsif new.unlock_all is distinct from old.unlock_all then
      new.unlock_all := old.unlock_all;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists protect_unlock_all on public.profiles;
create trigger protect_unlock_all
  before insert or update on public.profiles
  for each row execute function public.protect_unlock_all();
