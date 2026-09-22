-- ===================================================================
-- EduNexus database schema (v2 — real courses, lessons and evidence)
-- Run in Supabase: SQL Editor -> New query -> Run. Safe to run twice.
-- ===================================================================

do $$ begin create type user_role as enum ('student','teacher','admin');
exception when duplicate_object then null; end $$;

-- people ------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users on delete cascade,
  full_name    text not null,
  role         user_role not null default 'student',
  grade        text,
  subject      text,
  admission_no text,
  goal         text,
  interests    text[],
  created_at   timestamptz not null default now()
);
alter table public.profiles add column if not exists goal text;
alter table public.profiles add column if not exists interests text[];

-- what teachers build ------------------------------------------------
create table if not exists public.courses (
  id          uuid primary key default gen_random_uuid(),
  teacher_id  uuid not null references public.profiles(id) on delete cascade,
  title       text not null,
  subject     text not null,
  code        text,
  description text,
  published   boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists public.lessons (
  id           uuid primary key default gen_random_uuid(),
  course_id    uuid not null references public.courses(id) on delete cascade,
  title        text not null,
  topic        text not null,
  position     int  not null default 1,
  duration_min int  not null default 20,
  body         text,
  checkpoint   jsonb,            -- {question, options[], answer, explanation}
  published    boolean not null default false,
  created_at   timestamptz not null default now()
);

create table if not exists public.enrollments (
  student_id uuid not null references public.profiles(id) on delete cascade,
  course_id  uuid not null references public.courses(id) on delete cascade,
  joined_at  timestamptz not null default now(),
  primary key (student_id, course_id)
);

-- evidence: every graded thing a student does ------------------------
create table if not exists public.attempts (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  kind       text not null,       -- lesson | quiz | examlens | mirage | paper | test
  subject    text,
  topic      text not null,
  score      numeric not null,    -- 0 to 100
  seconds    int,
  lesson_id  uuid references public.lessons(id) on delete set null,
  meta       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.lessons add column if not exists video_url  text;
alter table public.lessons add column if not exists transcript text;
alter table public.lessons add column if not exists summary    text;

create index if not exists attempts_student_idx on public.attempts(student_id, created_at desc);

create table if not exists public.portfolio_items (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.profiles(id) on delete cascade,
  title       text not null,
  kind        text not null default 'Project',
  description text,
  link        text,
  visible     boolean not null default true,
  verified    boolean not null default false,
  created_at  timestamptz not null default now()
);

-- Edu AI chat history: so it survives logging out and back in --------
create table if not exists public.chat_messages (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  role       text not null,   -- user | assistant
  content    text not null,
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_student_idx on public.chat_messages(student_id, created_at);

-- who is staff --------------------------------------------------------
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('teacher','admin'));
$$;

-- row level security ---------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.courses         enable row level security;
alter table public.lessons         enable row level security;
alter table public.enrollments     enable row level security;
alter table public.attempts        enable row level security;
alter table public.portfolio_items enable row level security;
alter table public.chat_messages   enable row level security;

-- drop older policies from v1 if they exist
drop policy if exists "read own profile"        on public.profiles;
drop policy if exists "staff read all profiles" on public.profiles;
drop policy if exists "update own profile"      on public.profiles;
drop policy if exists "insert own profile"      on public.profiles;
drop policy if exists p_profiles_self  on public.profiles;
drop policy if exists p_profiles_staff on public.profiles;
drop policy if exists p_profiles_upd   on public.profiles;
drop policy if exists p_profiles_ins   on public.profiles;
drop policy if exists p_courses_read   on public.courses;
drop policy if exists p_courses_write  on public.courses;
drop policy if exists p_lessons_read   on public.lessons;
drop policy if exists p_lessons_write  on public.lessons;
drop policy if exists p_enrol_own      on public.enrollments;
drop policy if exists p_enrol_staff    on public.enrollments;
drop policy if exists p_attempts_own   on public.attempts;
drop policy if exists p_attempts_staff on public.attempts;
drop policy if exists p_portfolio_own   on public.portfolio_items;
drop policy if exists p_portfolio_staff on public.portfolio_items;
drop policy if exists p_chat_own on public.chat_messages;

create policy p_profiles_self    on public.profiles for select using (auth.uid() = id);
create policy p_profiles_staff   on public.profiles for select using (public.is_staff());
create policy p_profiles_upd     on public.profiles for update using (auth.uid() = id);
create policy p_profiles_ins     on public.profiles for insert with check (auth.uid() = id);

create policy p_courses_read     on public.courses for select using (published or teacher_id = auth.uid());
create policy p_courses_write    on public.courses for all    using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());

create policy p_lessons_read     on public.lessons for select using (
  exists (select 1 from public.courses c where c.id = course_id and (c.published or c.teacher_id = auth.uid())));
create policy p_lessons_write    on public.lessons for all using (
  exists (select 1 from public.courses c where c.id = course_id and c.teacher_id = auth.uid()))
  with check (exists (select 1 from public.courses c where c.id = course_id and c.teacher_id = auth.uid()));

create policy p_enrol_own        on public.enrollments for all using (student_id = auth.uid()) with check (student_id = auth.uid());
create policy p_enrol_staff      on public.enrollments for select using (public.is_staff());

create policy p_attempts_own     on public.attempts for all using (student_id = auth.uid()) with check (student_id = auth.uid());
create policy p_attempts_staff   on public.attempts for select using (public.is_staff());

create policy p_portfolio_own    on public.portfolio_items for all using (student_id = auth.uid()) with check (student_id = auth.uid());
create policy p_portfolio_staff  on public.portfolio_items for select using (public.is_staff());

-- Edu AI chat is private even from teachers, per the app's own privacy claim
create policy p_chat_own on public.chat_messages for all using (student_id = auth.uid()) with check (student_id = auth.uid());

-- profile created automatically on register ------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, role, grade, subject)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name','New user'),
          coalesce((new.raw_user_meta_data->>'role')::user_role,'student'),
          new.raw_user_meta_data->>'grade',
          new.raw_user_meta_data->>'subject')
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();


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


-- ===================================================================
-- EduNexus: name styles (the font and colour your name shows in).
-- Run once in the Supabase SQL Editor. Safe to run twice.
-- ===================================================================
alter table public.profiles add column if not exists name_style text not null default 'plain';


-- ===================================================================
-- EduNexus: the teaching assistant's conversation and memory.
-- Run once in the Supabase SQL Editor. Safe to run twice.
-- Each teacher can only ever see and change their own rows.
-- ===================================================================

create table if not exists public.assistant_messages (
  id         uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  role       text not null check (role in ('user','assistant')),
  content    text not null,
  created_at timestamptz not null default now()
);
create index if not exists assistant_messages_teacher_idx on public.assistant_messages(teacher_id, created_at);

-- Durable facts the assistant keeps between conversations:
-- preferences, plans, decisions, context about the class.
create table if not exists public.assistant_memory (
  id         uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  note       text not null check (char_length(note) between 1 and 400),
  source     text not null default 'assistant' check (source in ('assistant','teacher')),
  created_at timestamptz not null default now()
);
create index if not exists assistant_memory_teacher_idx on public.assistant_memory(teacher_id, created_at);

alter table public.assistant_messages enable row level security;
alter table public.assistant_memory   enable row level security;

drop policy if exists p_amsg_own on public.assistant_messages;
drop policy if exists p_amem_own on public.assistant_memory;
create policy p_amsg_own on public.assistant_messages for all
  using (teacher_id = auth.uid() and public.is_staff())
  with check (teacher_id = auth.uid() and public.is_staff());
create policy p_amem_own on public.assistant_memory for all
  using (teacher_id = auth.uid() and public.is_staff())
  with check (teacher_id = auth.uid() and public.is_staff());
