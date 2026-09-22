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
