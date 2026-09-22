-- ===================================================================
-- EduNexus: name styles (the font and colour your name shows in).
-- Run once in the Supabase SQL Editor. Safe to run twice.
-- ===================================================================
alter table public.profiles add column if not exists name_style text not null default 'plain';
