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
-- One student can hold several separate conversations (chat_threads), each
-- with its own title, like a normal chat app rather than one long transcript.
create table if not exists public.chat_threads (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  title      text not null default 'New chat',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists chat_threads_student_idx on public.chat_threads(student_id, updated_at desc);

create table if not exists public.chat_messages (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  thread_id  uuid references public.chat_threads(id) on delete cascade,
  role       text not null,   -- user | assistant
  content    text not null,
  created_at timestamptz not null default now()
);
-- Belt and braces: the CREATE TABLE above is skipped if chat_messages already
-- existed from before threads were added, so make sure the column is really
-- there before anything indexes it.
alter table public.chat_messages add column if not exists thread_id uuid references public.chat_threads(id) on delete cascade;
create index if not exists chat_messages_student_idx on public.chat_messages(student_id, created_at);
create index if not exists chat_messages_thread_idx on public.chat_messages(thread_id, created_at);

-- Backfill: any message from before threads existed gets folded into one
-- thread per student, so nothing already saved is orphaned or lost.
do $$
declare r record; new_thread uuid;
begin
  for r in select distinct student_id from public.chat_messages where thread_id is null loop
    insert into public.chat_threads (student_id, title) values (r.student_id, 'Earlier conversation') returning id into new_thread;
    update public.chat_messages set thread_id = new_thread where student_id = r.student_id and thread_id is null;
  end loop;
end $$;

-- Durable facts Edu AI keeps about a student across every thread — mirrors
-- the teacher assistant's memory, so a goal mentioned in one chat still
-- informs the next one, the way it would carry across ChatGPT conversations.
create table if not exists public.student_memory (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  note       text not null check (char_length(note) between 1 and 400),
  source     text not null default 'assistant' check (source in ('assistant','student')),
  created_at timestamptz not null default now()
);
create index if not exists student_memory_student_idx on public.student_memory(student_id, created_at);

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
alter table public.chat_threads    enable row level security;
alter table public.student_memory  enable row level security;

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
drop policy if exists p_chat_threads_own on public.chat_threads;
drop policy if exists p_student_memory_own on public.student_memory;

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
create policy p_chat_threads_own on public.chat_threads for all using (student_id = auth.uid()) with check (student_id = auth.uid());
create policy p_student_memory_own on public.student_memory for all using (student_id = auth.uid()) with check (student_id = auth.uid());

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


-- ===================================================================
-- EduNexus: tests and test papers.
-- Run once in the Supabase SQL Editor. Safe to run twice.
--
-- Answer keys live in their own table so a student can never read them,
-- and marks live in their own table so a student sees them only once the
-- teacher releases the results.
-- ===================================================================

create table if not exists public.tests (
  id           uuid primary key default gen_random_uuid(),
  teacher_id   uuid not null references public.profiles(id) on delete cascade,
  course_id    uuid references public.courses(id) on delete set null,
  title        text not null,
  subject      text not null,
  topic        text not null,
  instructions text,
  duration_min int,
  status       text not null default 'draft' check (status in ('draft','published','closed')),
  created_at   timestamptz not null default now()
);

create table if not exists public.test_questions (
  id        uuid primary key default gen_random_uuid(),
  test_id   uuid not null references public.tests(id) on delete cascade,
  position  int  not null default 1,
  kind      text not null check (kind in ('mcq','theory','drawing')),
  prompt    text not null,
  options   jsonb,                       -- mcq only: ["A","B","C"]
  marks     int  not null default 1,
  created_at timestamptz not null default now()
);

-- teacher only: correct answers and mark schemes
create table if not exists public.question_key (
  question_id  uuid primary key references public.test_questions(id) on delete cascade,
  test_id      uuid not null references public.tests(id) on delete cascade,
  answer_index int,      -- mcq
  expected     text      -- theory / drawing mark scheme
);

create table if not exists public.test_submissions (
  id           uuid primary key default gen_random_uuid(),
  test_id      uuid not null references public.tests(id) on delete cascade,
  student_id   uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'submitted' check (status in ('submitted','marked','released')),
  total_score  numeric,
  total_marks  int,
  submitted_at timestamptz not null default now(),
  released_at  timestamptz,
  unique (test_id, student_id)
);

-- what the student wrote
create table if not exists public.test_answers (
  submission_id uuid not null references public.test_submissions(id) on delete cascade,
  question_id   uuid not null references public.test_questions(id) on delete cascade,
  response      text,
  chosen_index  int,
  image_url     text,
  primary key (submission_id, question_id)
);

-- what the marking says; students read it only after release
create table if not exists public.test_marks (
  submission_id uuid not null references public.test_submissions(id) on delete cascade,
  question_id   uuid not null references public.test_questions(id) on delete cascade,
  score         numeric not null default 0,
  max_marks     int not null default 1,
  feedback      text,
  correct       text,          -- the right answer, shown to the student after release
  ai_score      numeric,       -- what the AI gave, kept so a teacher override is visible
  confidence    text,          -- high | medium | low
  marked_by     text not null default 'ai' check (marked_by in ('ai','teacher')),
  primary key (submission_id, question_id)
);

create index if not exists tests_teacher_idx on public.tests(teacher_id);
create index if not exists tq_test_idx on public.test_questions(test_id, position);
create index if not exists ts_test_idx on public.test_submissions(test_id);
create index if not exists ts_student_idx on public.test_submissions(student_id);

alter table public.tests            enable row level security;
alter table public.test_questions   enable row level security;
alter table public.question_key     enable row level security;
alter table public.test_submissions enable row level security;
alter table public.test_answers     enable row level security;
alter table public.test_marks       enable row level security;

do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies where schemaname='public'
           and tablename in ('tests','test_questions','question_key','test_submissions','test_answers','test_marks')
  loop execute format('drop policy %I on public.%I', r.policyname, r.tablename); end loop;
end $$;

-- tests: the teacher owns them; students see published ones
create policy p_tests_owner on public.tests for all
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());
create policy p_tests_read on public.tests for select
  using (status in ('published','closed'));

-- questions follow their test; the key never leaves the teacher
create policy p_tq_owner on public.test_questions for all
  using (exists (select 1 from public.tests t where t.id = test_id and t.teacher_id = auth.uid()))
  with check (exists (select 1 from public.tests t where t.id = test_id and t.teacher_id = auth.uid()));
create policy p_tq_read on public.test_questions for select
  using (exists (select 1 from public.tests t where t.id = test_id and t.status in ('published','closed')));
create policy p_key_owner on public.question_key for all
  using (exists (select 1 from public.tests t where t.id = test_id and t.teacher_id = auth.uid()))
  with check (exists (select 1 from public.tests t where t.id = test_id and t.teacher_id = auth.uid()));

-- submissions: the student's own; the teacher of that test can read and mark
create policy p_sub_student on public.test_submissions for all
  using (student_id = auth.uid()) with check (student_id = auth.uid());
create policy p_sub_teacher on public.test_submissions for select
  using (exists (select 1 from public.tests t where t.id = test_id and t.teacher_id = auth.uid()));
create policy p_sub_teacher_upd on public.test_submissions for update
  using (exists (select 1 from public.tests t where t.id = test_id and t.teacher_id = auth.uid()));

create policy p_ans_student on public.test_answers for all
  using (exists (select 1 from public.test_submissions s where s.id = submission_id and s.student_id = auth.uid()))
  with check (exists (select 1 from public.test_submissions s where s.id = submission_id and s.student_id = auth.uid()));
create policy p_ans_teacher on public.test_answers for select
  using (exists (select 1 from public.test_submissions s join public.tests t on t.id = s.test_id
                 where s.id = submission_id and t.teacher_id = auth.uid()));

-- marks: the teacher writes them; the student reads them only once released
create policy p_marks_teacher on public.test_marks for all
  using (exists (select 1 from public.test_submissions s join public.tests t on t.id = s.test_id
                 where s.id = submission_id and t.teacher_id = auth.uid()))
  with check (exists (select 1 from public.test_submissions s join public.tests t on t.id = s.test_id
                 where s.id = submission_id and t.teacher_id = auth.uid()));
create policy p_marks_student on public.test_marks for select
  using (exists (select 1 from public.test_submissions s
                 where s.id = submission_id and s.student_id = auth.uid() and s.status = 'released'));

-- releasing a test writes the result into the student's genome
drop policy if exists p_attempts_staff_ins on public.attempts;
create policy p_attempts_staff_ins on public.attempts for insert with check (public.is_staff());

-- photos of handwritten or drawn answers
insert into storage.buckets (id, name, public) values ('test-uploads','test-uploads', true)
on conflict (id) do nothing;
drop policy if exists "test uploads read"   on storage.objects;
drop policy if exists "test uploads write"  on storage.objects;
create policy "test uploads read"  on storage.objects for select
  using (bucket_id = 'test-uploads');
create policy "test uploads write" on storage.objects for insert
  with check (bucket_id = 'test-uploads' and (storage.foldername(name))[1] = auth.uid()::text);
