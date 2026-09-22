<p align="center">
  <img src="branding/EduNexus-wordmark-transparent.png" alt="EduNexus" width="320">
</p>

<p align="center">
  <strong>AI-powered school & student development platform</strong><br>
  CodeFest 2026 · AI Senior Category · Team G027, Miracle International School
</p>

---

## The problem

Learning is fragmented — lessons, exams, marks, and personal achievements all live in separate places. A low mark tells a student *what* happened, but not *why*, and even when they know their weaknesses, they're left to figure out the priorities themselves. Most school platforms just record progress. EduNexus tries to understand it, and tell you what to do next.

## What it is

EduNexus is built around a **Learning Genome** — a live, per-topic mastery score computed from a student's own graded work, weighted by how reliable that kind of evidence is (a full test counts for more than a lesson checkpoint) and faded by age. Nothing in it is mock data or a stored flag; every number changes the moment new evidence comes in, and everything else on the platform reads from that same record — a weakness ExamLens finds shows up in the Genome instantly and shapes what the AI says next.

## Modules

- **Learning Genome** — live topic mastery, computed from every piece of graded work, decayed by age
- **ExamLens** — marks one exam answer, typed or photographed (OCR via a vision model), and names *why* the marks were lost, not just the score
- **Mirage** — a run of questions at increasing distance from the taught form, to separate genuine understanding from pattern memorisation
- **Study Doctor** — diagnoses a fortnight of work, reasoning about prerequisite topics rather than weak scores in isolation
- **Edu AI (AI Counselor)** — a study assistant grounded only in a student's own evidence, with real multi-chat conversations and persistent memory that survives across every chat — a goal or preference mentioned once is still known in a completely different conversation later, the way ChatGPT's memory works
- **Student Profile, Advisor & Portfolio** — subjects, goals and interests in one record; the Advisor recommends pathways against the Genome; the Portfolio turns achievements into a shareable profile
- **Teaching assistant** — the class-level counterpart for teachers: spots shared misconceptions, flags who needs attention, and keeps its own durable memory between conversations
- **Badges** — computed live from real activity (streaks, evidence collected, genuine mastery), never a stored flag, with a full-screen unlock celebration

## How it's built

- **Supabase** — Postgres, Auth, Edge Functions and Storage. Access control is enforced by row-level security policies, not by what the interface shows — a student's Edu AI conversations, for example, have no staff-read policy at all, so a teacher account cannot read them regardless of the UI.
- **Vanilla JavaScript** — a single responsive web app with no build step: a hash router, template-string views, one global state object. Runs the same on mobile and desktop from one codebase, `app.html`; `login.html` handles sign-in and registration.
- **Groq** — `openai/gpt-oss-120b` for reasoning and chat, and `qwen/qwen3.8-27b` for reading photographed or handwritten exam answers in ExamLens. Every model call is routed through a Supabase Edge Function that checks the caller's identity first, so the API key never touches the browser, and every prompt is grounded in that student's own Learning Genome rather than giving generic advice.

## Getting started

Full setup — database, environment, deploying the AI function, and a step-by-step demo script — is in **[SETUP.md](SETUP.md)**. Short version: run `schema.sql` in Supabase, drop your project URL/key into `config.js`, deploy `supabase/functions/ai/index.ts`, then serve the folder statically and open `login.html`.

## Team

**R.M. Methdinu D. Rajaguru** — originated EduNexus: the concept, the nine-module architecture, and the full initial pitch and design (see [the concept deck](docs/EduNexus-CodeFest-2026-Concept-Deck.pdf) and [project summary](docs/EduNexus-CodeFest-2026-Project-Summary.pdf)). Built the platform's initial working version, the badge and cosmetics system, avatar borders and profile customisation, the first version of the teaching assistant, and a mobile UI redesign.

**Thewindu Sathsara Amaneth Wijesiri** — built out the platform from that foundation: ExamLens's photo/OCR marking pipeline, Mirage, Study Doctor's prerequisite reasoning, Edu AI's persistent multi-chat with cross-conversation memory, the badge-unlock celebration, and sign-in and interaction polish across the app.

Both contributed ongoing fixes, live testing, and ordinary changes throughout — see the git history for the detailed, dated record.

## Competition

Submitted to **CodeFest 2026**, AI Senior Category, organised by SLIIT (Sri Lanka Institute of Information Technology) — team G027, Miracle International School.

## Honest limitations

Worth knowing before you ask — see the full list in [SETUP.md](SETUP.md#honest-limits-worth-knowing-before-judges-ask).

## License

MIT — see [LICENSE](LICENSE).
