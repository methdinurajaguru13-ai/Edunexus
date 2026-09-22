# EduNexus: setup

Files:

- `login.html` — sign in and register, students and teachers
- `app.html` — the platform
- `config.js` — your Supabase URL and key
- `schema.sql` — the database
- `supabase/functions/ai/index.ts` — the AI service, where the Groq key lives

Nothing in the app is mock data any more. A new account starts empty and fills up as work is done.

---

## Part 1: The database (15 minutes)

**1. Create a Supabase project.** Sign up at supabase.com, create a project, choose the Singapore region, and save the database password.

**2. Run the schema.** Open SQL Editor, click New query, paste all of `schema.sql`, click Run. It creates `profiles`, `courses`, `lessons`, `enrollments`, `attempts` and `portfolio_items`, and switches on the access rules. Safe to run more than once. If you ran the older version of this file before, running this one updates it.

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

---

## How to demo it

Do this in order, with two accounts.

**As a teacher:**
1. Register, choosing Teacher.
2. Courses → create one, for example Physics 9702 with subject Physics.
3. Add a lesson: type a title and topic, click "Draft notes with AI", then "Write the checkpoint with AI". Edit whatever it gives you, then click Add lesson.
4. Publish the course.

**As a student, in another browser or a private window:**
5. Register as Student, open Learn, join the course.
6. Open the lesson, answer the checkpoint. The AI explains your reasoning and the result is written to your genome.
7. Open ExamLens, paste a real exam question and a wrong answer on purpose. It marks it, names the cause, and records it.
8. Open Mirage, pick a topic, and it writes five questions at increasing distance from the taught form. Answer them and it separates apparent mastery from genuine mastery.
9. Open Study doctor and diagnose the fortnight, then open Edu AI and ask what to work on. Every answer is built from the rows you just created.

**Back as the teacher:**
10. My class shows that student, their genome score and their weakest topic. Click them to see the topic breakdown, read only.

That sequence is the whole product in about four minutes, with no invented data anywhere in it.

---

## What each part actually does

**The genome** is computed in the browser from the `attempts` table: score = sum of (result × source weight × decay) ÷ sum of (source weight × decay), per topic. Weights are test 30, practice paper 22, ExamLens 18, Mirage 18, quiz 14, Study Doctor 10, lesson checkpoint 6, and every result fades with a 60-day half-life. The scoring page inside the app shows this to the user.

**The AI** runs on gpt-oss-120b through Groq, called only from the Edge Function. The function verifies the caller's JWT, loads that student's own profile and attempts, builds the prompt, and instructs the model to use only that evidence. Tasks: chat, checkpoint feedback, lesson drafting, checkpoint writing, ExamLens marking, Mirage generation and marking, Study Doctor diagnosis, and pathway advice.

**Access rules** are enforced by PostgreSQL, not by the interface. Students can only read and write their own rows. Teachers can read student records but never write to them. Nobody can read another student's portfolio drafts or Edu AI conversations.

---

## Honest limits, worth knowing before judges ask

- ExamLens takes typed text. Handwritten or scanned papers need OCR first, which isn't built.
- Mirage marks short written answers with the model, so its marking is as good as the model is. Expect the occasional generous mark.
- There's no timetable, attendance or school news yet. Those slides are still future work.
- Lesson checkpoints are multiple choice.
- Anyone with a school email can register as a teacher. A real deployment needs the school to approve staff accounts.

---

## If something breaks

**"Not connected"** — `config.js` still holds the placeholder text.

**Registering fails with a database error** — `schema.sql` hasn't run, or only partly. Run it again.

**Signed in but bounced back to login** — the profile row wasn't created. Re-run the trigger section at the end of `schema.sql`.

**AI features say they can't reach the service** — the function isn't deployed, or `GROQ_API_KEY` isn't set. Check Edge Functions → Logs in the dashboard for the real error.

**Student sees no courses** — the teacher hasn't clicked Publish on the course.

**Checkpoint doesn't record anything** — the lesson was added without a checkpoint. Lessons without one teach, but don't measure.
