-- ===================================================================
-- EduNexus: per-account settings, synced across devices.
-- Run once in the Supabase SQL Editor. Safe to run twice.
-- ===================================================================
alter table public.profiles add column if not exists settings jsonb not null default '{}'::jsonb;
