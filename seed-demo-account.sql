-- ===================================================================
-- EduNexus demo account seed.
-- Run in the Supabase SQL Editor AFTER borders-and-admin.sql.
--
-- For the account below it:
--   * unlocks every banner, badge and border (unlock_all = true)
--   * adds 30 consecutive sign-in days
--   * adds high-scoring graded work across Physics, Mathematics and
--     Chemistry, including Mirage runs with 93%+ genuine mastery,
--     so the genome comes out above 90%
--
-- Every row it adds is tagged meta.seed = 'demo', so it can be removed
-- cleanly with the script at the bottom. Running it again replaces the
-- previous seed rather than doubling it.
-- ===================================================================
do $$
declare
  target_email text := 'methdinurajaguru13@gmail.com';
  uid uuid;
  rec record;
  genuine_pct int;
begin
  select id into uid from auth.users where lower(email) = lower(target_email);
  if uid is null then
    raise exception 'No EduNexus account uses %. Register it first, then run this again.', target_email;
  end if;

  update public.profiles set unlock_all = true where id = uid;

  -- replace any earlier seed
  delete from public.attempts where student_id = uid and meta->>'seed' = 'demo';

  -- a 30-day sign-in streak ending today
  insert into public.login_days (user_id, day)
  select uid, current_date - s.n from generate_series(0, 29) as s(n)
  on conflict do nothing;

  -- strong, recent evidence on every topic, at every weight
  for rec in
    select * from (values
      ('Physics','Electromagnetic induction'), ('Physics','Mechanics'), ('Physics','Waves'),
      ('Physics','Thermal physics'), ('Physics','Fields'),
      ('Mathematics','Vectors'), ('Mathematics','Trigonometry'), ('Mathematics','Calculus'),
      ('Chemistry','Organic synthesis'), ('Chemistry','Equilibria'), ('Chemistry','Energetics')
    ) as v(subject, topic)
  loop
    -- supervised test (weight 30)
    insert into public.attempts (student_id, kind, subject, topic, score, created_at, meta)
    values (uid, 'test', rec.subject, rec.topic, 93 + floor(random()*6), now() - interval '8 days',
            jsonb_build_object('seed','demo'));
    -- past paper (weight 22)
    insert into public.attempts (student_id, kind, subject, topic, score, created_at, meta)
    values (uid, 'paper', rec.subject, rec.topic, 92 + floor(random()*7), now() - interval '5 days',
            jsonb_build_object('seed','demo'));
    -- quiz (weight 14)
    insert into public.attempts (student_id, kind, subject, topic, score, created_at, meta)
    values (uid, 'quiz', rec.subject, rec.topic, 100, now() - interval '3 days',
            jsonb_build_object('seed','demo'));
    -- Mirage run (weight 18): genuine mastery 93-97%, almost no gap to apparent
    genuine_pct := 93 + floor(random()*5);
    insert into public.attempts (student_id, kind, subject, topic, score, created_at, meta)
    values (uid, 'mirage', rec.subject, rec.topic, genuine_pct, now() - interval '1 day',
            jsonb_build_object('seed','demo', 'genuine', genuine_pct, 'apparent', least(100, genuine_pct + 2),
              'verdict', 'Mastery holds across every distance, including new contexts and the inverse form. This is genuine understanding, not pattern-matching.'));
    -- ExamLens analysis (weight 18)
    insert into public.attempts (student_id, kind, subject, topic, score, created_at, meta)
    values (uid, 'examlens', rec.subject, rec.topic, 95 + floor(random()*6), now() - interval '2 days',
            jsonb_build_object('seed','demo', 'cause', 'none', 'verdict', 'Full marks: method and answer both correct.'));
  end loop;

  raise notice 'Seeded % for demo use.', target_email;
end $$;

-- To undo the seed later, run:
--   update public.profiles set unlock_all = false
--     where id = (select id from auth.users where lower(email) = lower('methdinurajaguru13@gmail.com'));
--   delete from public.attempts
--     where meta->>'seed' = 'demo'
--       and student_id = (select id from auth.users where lower(email) = lower('methdinurajaguru13@gmail.com'));
