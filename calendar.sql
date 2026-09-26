-- ===================================================================
-- EduNexus: timetable and calendar.
-- Run once in the Supabase SQL Editor. Safe to run twice.
-- ===================================================================

-- the repeating week: lessons, frees, clubs
create table if not exists public.timetable_slots (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  day        int  not null check (day between 1 and 7),   -- 1 = Monday
  starts     time not null,
  ends       time not null,
  title      text not null,
  subject    text,
  location   text,
  created_at timestamptz not null default now()
);
create index if not exists tt_user_idx on public.timetable_slots(user_id, day, starts);

-- one-off things: tests, deadlines, events, study sessions
create table if not exists public.events (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  audience   text not null default 'me' check (audience in ('me','class','school')),
  course_id  uuid references public.courses(id) on delete cascade,
  kind       text not null default 'event' check (kind in ('event','exam','deadline','study','holiday','reminder')),
  title      text not null,
  notes      text,
  location   text,
  starts_at  timestamptz not null,
  ends_at    timestamptz,
  all_day    boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists ev_owner_idx on public.events(owner_id, starts_at);
create index if not exists ev_when_idx  on public.events(starts_at);

-- tests can carry a due date, so they appear in the calendar
alter table public.tests add column if not exists due_at timestamptz;

alter table public.timetable_slots enable row level security;
alter table public.events          enable row level security;

do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies where schemaname='public'
           and tablename in ('timetable_slots','events')
  loop execute format('drop policy %I on public.%I', r.policyname, r.tablename); end loop;
end $$;

-- your own week is yours alone
create policy p_tt_own on public.timetable_slots for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- your own events, plus anything shared with your class or the school
create policy p_ev_own on public.events for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy p_ev_school on public.events for select
  using (audience = 'school');
create policy p_ev_class on public.events for select
  using (audience = 'class' and (
    exists (select 1 from public.enrollments e where e.course_id = events.course_id and e.student_id = auth.uid())
    or exists (select 1 from public.courses c where c.id = events.course_id and c.teacher_id = auth.uid())));

-- only staff may post to a whole class or the whole school
create or replace function public.check_event_audience()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.audience <> 'me' and not public.is_staff() then
    raise exception 'Only teachers can share events with a class or the school';
  end if;
  return new;
end $$;
drop trigger if exists check_event_audience on public.events;
create trigger check_event_audience before insert or update on public.events
  for each row execute function public.check_event_audience();
