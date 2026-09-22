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
