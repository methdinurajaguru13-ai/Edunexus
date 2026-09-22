-- ===================================================================
-- EduNexus: profile photos, banners, badges and login tracking.
-- Run once in Supabase SQL Editor. Safe to run twice.
-- (Also appended to schema.sql, so a fresh setup gets it automatically.)
-- ===================================================================

-- what a person has chosen to show
alter table public.profiles add column if not exists avatar_url   text;
alter table public.profiles add column if not exists banner       text not null default 'circuit';
alter table public.profiles add column if not exists badges_shown text[] not null default '{}';

-- at most three badges on a banner, enforced by the database itself
do $$ begin
  alter table public.profiles add constraint badges_shown_max_three
    check (coalesce(array_length(badges_shown, 1), 0) <= 3);
exception when duplicate_object then null; end $$;

-- one row per person per day they signed in: powers the login badges
create table if not exists public.login_days (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day     date not null default current_date,
  primary key (user_id, day)
);
alter table public.login_days enable row level security;
drop policy if exists p_login_own   on public.login_days;
drop policy if exists p_login_staff on public.login_days;
create policy p_login_own   on public.login_days for all    using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy p_login_staff on public.login_days for select using (public.is_staff());

-- profile photos: a public bucket, but each person can only write inside their own folder
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

drop policy if exists "avatars public read" on storage.objects;
drop policy if exists "avatars own insert"  on storage.objects;
drop policy if exists "avatars own update"  on storage.objects;
drop policy if exists "avatars own delete"  on storage.objects;

create policy "avatars public read" on storage.objects for select
  using (bucket_id = 'avatars');
create policy "avatars own insert" on storage.objects for insert
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars own update" on storage.objects for update
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars own delete" on storage.objects for delete
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
