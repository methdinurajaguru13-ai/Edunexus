# EduNexus: setup

Files:

- `login.html` — sign in and register, students and teachers
- `app.html` — the platform
- `config.js` — your Supabase URL and key
- `schema.sql` — the database
- `supabase/functions/ai/index.ts` — the AI service, where the Groq key lives

Nothing in the app is mock data. A new account starts empty and fills up as work is done.

---

## Part 1: The database (15 minutes)

**1. Create a Supabase project.** Sign up at supabase.com, create a project, choose the Singapore region, and save the database password.

**2. Run the schema.** Open SQL Editor, click New query, paste all of `schema.sql`, click Run. It creates `profiles`, `courses`, `lessons`, `enrollments`, `attempts`, `portfolio_items`, `chat_threads`, `chat_messages`, `student_memory`, `assistant_messages`, `assistant_memory`, and the standardized-test tables (`tests`, `test_questions`, `question_key`, `test_submissions`, `test_answers`, `test_marks`) — and switches on the access rules for all of it. Safe to run more than once — later runs pick up wherever an earlier version of this file left off, including backfilling any pre-existing chat history into a thread so nothing is orphaned.

**3. Turn off email confirmation while testing.** Authentication → Sign In / Providers → Email → turn off Confirm email. Turn it back on before real students use it.

**4. Get your URL and key.** Click **Connect** at the top of your project dashboard, or go to Settings → API Keys. Copy the Project URL (ends in `.supabase.co`) and the publishable key (`sb_publishable_…`) or the legacy `anon` key. Paste both into `config.js`. Never use the secret or `service_role` key here.

**5. Run it.** In a terminal in this folder: `python3 -m http.server 8000`, then open `http://localhost:8000/login.html`.

At this point accounts, courses, lessons and the genome all work. The AI features will say they can't reach the service until you finish part 2.

---

## Part 2: The AI (15 minutes)

The Groq key must never sit in the browser, so it lives in a Supabase Edge Function that checks who's asking before it answers.

**1. Get a Groq key.** Sign up at console.groq.com, go to API Keys, create one, and copy it. It's shown once.

**2. Install the Supabase CLI.**

    npm install -g supabase

**3. Link and deploy.** Your project ref is in your dashboard URL, the part after `/project/`.

    supabase login
    supabase link --project-ref YOUR_PROJECT_REF
    supabase secrets set GROQ_API_KEY=your_groq_key_here
    supabase functions deploy ai

**4. Check it.** Reload the app, open Edu AI, and ask something. If it answers, the whole chain works: your browser, your JWT, the function, Groq, and back.

No terminal? In the dashboard, open Edge Functions, create one named exactly `ai`, paste the contents of `supabase/functions/ai/index.ts`, and deploy. Add `GROQ_API_KEY` under Edge Functions → Secrets.

**Whenever `index.ts` changes, it has to be redeployed separately** — editing the file or pushing it to git does nothing to the live function on its own. This has bitten us before: a feature can look "done" in the repo while the deployed function is still running the old version.

---

## How to demo it

Do this in order, with two accounts. About six minutes end to end.

**As a teacher:**
1. Register, choosing Teacher.
2. Courses → create one, for example Physics 9702 with subject Physics.
3. Add a lesson: type a title and topic, click "Draft notes with AI", then "Write the checkpoint with AI". Edit whatever it gives you, then click Add lesson.
4. Publish the course.
5. Open Edu AI (the teaching assistant) and ask "Who needs my attention this week?" — it reads real class data, and tell it something to remember (e.g. a plan or a preference); that note will still be there in a future conversation, not just this one.

**As a student, in another browser or a private window:**
6. Register as Student — watch for the "First Day" badge to unlock full-screen on first sign-in.
7. Open Learn, join the course — "Enrolled" unlocks the same way.
8. Open the lesson, answer the checkpoint. The AI explains your reasoning and the result is written to your genome. This is also usually the first graded work, so "First Steps" unlocks too.
9. Open ExamLens. Either type a wrong answer on purpose, or use "Read photo with AI" to OCR a handwritten/photographed answer straight from a camera or photo library — either way it marks it, names the cause of the lost marks, and records it.
10. Open Mirage, pick a topic — it writes five questions at increasing distance from the taught form. Answer them and it separates apparent mastery from genuine mastery.
11. Open Study doctor and diagnose the fortnight — it reasons about prerequisite topics, not just weak scores.
12. Open Edu AI. Mention a goal or preference ("I'm aiming for mechanical engineering"), then click **+ New chat** to start a completely separate conversation and ask what it remembers about you — it should recall the goal even though that's a different thread with no shared history. This is the ChatGPT-style cross-chat memory, distinct from any single conversation's own context.

**Back as the teacher:**
13. My class shows that student, their genome score and their weakest topic. Click them to see the topic breakdown, read only.

That sequence is the whole product, with no invented data anywhere in it.

---

## What each part actually does

**The genome** is computed in the browser from the `attempts` table: score = sum of (result × source weight × decay) ÷ sum of (source weight × decay), per topic. Weights are test 30, practice paper 22, ExamLens 18, Mirage 18, quiz 14, Study Doctor 10, lesson checkpoint 6, and every result fades with a 60-day half-life. The scoring page inside the app shows this to the user.

**The AI** runs on `gpt-oss-120b` through Groq for text, and `qwen/qwen3.8-27b` — the only vision-capable model Groq currently hosts — for reading photographed or handwritten answers in ExamLens. Every call goes only through the Edge Function, which verifies the caller's JWT, loads that student's own profile and attempts, builds the prompt, and instructs the model to use only that evidence. Tasks: chat, chat title generation, checkpoint feedback, lesson drafting, checkpoint writing, video-transcript summarising, ExamLens marking (text and photo), Mirage generation and marking, Study Doctor diagnosis, pathway advice, and the teaching assistant.

**Edu AI's memory** works the same way for students and teachers: durable notes (goals, preferences, plans — never grades, those are live data) that persist across every conversation, not just the one they were mentioned in. Students additionally get separate chat threads, like a normal chat app, with AI-written titles; the memory is shared across all of a student's threads, while each thread's own conversation stays isolated to itself.

**Badges** are computed the same way as the genome — read live from `attempts`, `login_days`, `portfolio_items` and enrollments, never stored as a flag. Unlocking one triggers a full-screen reveal using the real badge artwork and its rarity tier's colour.

**Standardized tests** let a teacher build a paper from MCQ, theory, or drawing questions, publish it, and students submit through the same account. Answer keys live in their own table (`question_key`) that students can never read, and marks live in their own table that only becomes visible to a student once the teacher explicitly releases results — a submission is invisible to its own author until then. Authoring itself is manual right now (add/reorder/mark-correct in the builder); the schema already has the columns for AI-assisted marking (`ai_score`, `confidence`, `marked_by`) but that path isn't wired into the Edge Function yet.

**Access rules** are enforced by PostgreSQL, not by the interface. Students can only read and write their own rows. Teachers can read student academic records but never write to them, and can never read a student's Edu AI conversations or memory — there's no staff-read policy on those tables at all, so it isn't a hidden UI restriction, it's enforced at the database level regardless of what the interface shows.

---

## Honest limits, worth knowing before judges ask

- ExamLens photo reading depends on Groq's vision model being available and within its rate limit; if it's briefly unavailable, typing the answer in still works as a fallback.
- Mirage marks short written answers with the model, so its marking is as good as the model is. Expect the occasional generous mark.
- Standardized-test marking is manual (teacher-scored), not AI-assisted yet, even though the data model is ready for it.
- There's no timetable, attendance or school news yet. Those slides are still future work.
- Lesson checkpoints are multiple choice.
- Anyone with a school email can register as a teacher. A real deployment needs the school to approve staff accounts.
- The confirmation email is sent through a personal Gmail account's SMTP relay rather than a dedicated transactional provider, so it can land in spam, especially on a first send to a given recipient. If a judge signs up live and doesn't see it, check spam.

---

## If something breaks

**"Not connected"** — `config.js` still holds the placeholder text.

**Registering fails with a database error** — `schema.sql` hasn't run, or only partly. Run it again.

**Signed in but bounced back to login** — the profile row wasn't created. Re-run the trigger section at the end of `schema.sql`.

**AI features say they can't reach the service** — the function isn't deployed, or `GROQ_API_KEY` isn't set. Check Edge Functions → Logs in the dashboard for the real error.

**A feature works in the code but not in the app** — the edge function almost certainly needs redeploying; see the note at the end of Part 2.

**Student sees no courses** — the teacher hasn't clicked Publish on the course.

**Checkpoint doesn't record anything** — the lesson was added without a checkpoint. Lessons without one teach, but don't measure.

**Edu AI has no memory of an earlier conversation** — check whether it was in a *different* chat thread than expected; per-thread history and cross-thread memory are two different things (see "What each part actually does" above).
