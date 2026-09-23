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
