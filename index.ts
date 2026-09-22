// EduNexus AI service.
// Runs on Supabase Edge Functions. The Groq key lives here, never in the browser.
// Deploy:  supabase functions deploy ai
// Secret:  supabase secrets set GROQ_API_KEY=your_key

import { createClient } from "jsr:@supabase/supabase-js@2";

const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";
const MODEL = "openai/gpt-oss-120b";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function groq(messages: unknown[], jsonMode = false) {
  const key = Deno.env.get("GROQ_API_KEY");
  if (!key) throw new Error("GROQ_API_KEY is not set on the function");
  const res = await fetch(GROQ_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODEL,
      messages,
      temperature: 0.3,
      max_tokens: 1200,
      ...(jsonMode ? { response_format: { type: "json_object" } } : {}),
    }),
  });
  if (!res.ok) throw new Error(`Model error ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const data = await res.json();
  return data.choices?.[0]?.message?.content ?? "";
}
const asJson = (text: string) => {
  const clean = text.replace(/```json|```/g, "").trim();
  try { return JSON.parse(clean); }
  catch { const m = clean.match(/[{[][\s\S]*[}\]]/); if (m) return JSON.parse(m[0]); throw new Error("Model did not return JSON"); }
};

/* Build a compact picture of the student from their own rows. */
function genomeSummary(attempts: any[]) {
  const W: Record<string, number> = { test: 30, paper: 22, examlens: 18, mirage: 18, quiz: 14, doctor: 10, lesson: 6 };
  const now = Date.now(), byTopic: Record<string, { num: number; den: number; n: number; subject: string }> = {};
  for (const a of attempts) {
    const w = W[a.kind] ?? 10;
    const days = (now - new Date(a.created_at).getTime()) / 86400000;
    const decay = Math.pow(0.5, days / 60);
    const t = (byTopic[a.topic] ||= { num: 0, den: 0, n: 0, subject: a.subject || "" });
    t.num += Number(a.score) * w * decay; t.den += w * decay; t.n++;
  }
  return Object.entries(byTopic)
    .map(([topic, v]) => ({ topic, subject: v.subject, score: Math.round(v.num / v.den), evidence: v.n }))
    .sort((a, b) => a.score - b.score);
}


/* ---- video captions ------------------------------------------------
   The model reads text, not pictures. So for a video we fetch the
   caption track and work from that. If a video has no captions, the
   teacher pastes the transcript instead. Nothing is guessed.
--------------------------------------------------------------------*/
function youtubeId(url: string) {
  const m = String(url).match(/(?:youtu\.be\/|v=|\/embed\/|\/shorts\/)([A-Za-z0-9_-]{11})/);
  return m ? m[1] : null;
}
async function fetchCaptions(url: string) {
  const id = youtubeId(url);
  if (!id) throw new Error("That doesn't look like a YouTube link. Paste the transcript instead.");
  const page = await fetch(`https://www.youtube.com/watch?v=${id}&hl=en`, {
    headers: { "User-Agent": "Mozilla/5.0", "Accept-Language": "en" },
  }).then(r => r.text());
  const tracks = page.match(/"captionTracks":(\[.*?\])/);
  if (!tracks) throw new Error("This video has no captions available. Paste the transcript instead.");
  const list = JSON.parse(tracks[1].replace(/\\u0026/g, "&"));
  const track = list.find((t: any) => (t.languageCode || "").startsWith("en")) ?? list[0];
  if (!track?.baseUrl) throw new Error("No usable caption track. Paste the transcript instead.");
  const data = await fetch(track.baseUrl + "&fmt=json3").then(r => r.json());
  const text = (data.events || [])
    .flatMap((e: any) => (e.segs || []).map((s: any) => s.utf8))
    .join("").replace(/\s+/g, " ").trim();
  if (!text) throw new Error("The caption track came back empty. Paste the transcript instead.");
  return text;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return json({ error: "Sign in first" }, 401);

    const { task, payload = {} } = await req.json();

    /* ---- context the student's own rows provide -------------------- */
    let profile: any = null, topics: any[] = [], recent: any[] = [];
    if (["chat", "doctor", "advisor"].includes(task)) {
      const { data: p } = await sb.from("profiles").select("full_name, role, grade, goal, interests").eq("id", user.id).single();
      profile = p;
      const { data: att } = await sb.from("attempts")
        .select("kind, subject, topic, score, seconds, meta, created_at")
        .eq("student_id", user.id).order("created_at", { ascending: false }).limit(120);
      recent = att ?? [];
      topics = genomeSummary(recent);
    }

    const PLATFORM = `
How EduNexus works, so you can answer questions about it:

The learning genome is the student's profile of what they know. It is not stored as a mark; it is recomputed from
every piece of graded work they have done. For each topic:
  score = sum of (result x source weight x decay) / sum of (source weight x decay)
Source weights out of 100: supervised test 30, practice or past paper 22, ExamLens analysis 18, Mirage run 18,
quiz 14, Study Doctor session 10, lesson checkpoint 6. Supervised work is weighted higher because it is harder to
guess your way through. Every result decays with a 60-day half-life, so work from two months ago counts half as much
as work done today. A topic with no evidence is left empty, never scored zero. Confidence shows how much evidence
sits behind a score.
A subject score is that same calculation across all of the subject's attempts. The genome screen is a web that drills
from subjects, to topics within a subject, to individual lessons and assessments within a topic.

What raises a genome score, in order of effect:
  1. New evidence at a higher weight. One timed paper or Mirage run moves a topic far more than another checkpoint.
  2. Fresh evidence. Old weak results fade on their own, so redoing a topic now outweighs what happened weeks ago.
  3. Breadth. A topic with one attempt behind it has low confidence; a second and third piece of evidence stabilises it.
Nothing is deleted and scores cannot be reset, so the only way up is more recent, better-weighted work.

The other parts: Learn holds the courses and lessons a teacher published, each lesson ending in a checkpoint.
ExamLens marks a real exam answer and classifies why marks were lost. Mirage asks the same idea five ways, from the
identical form to the inverse, to separate apparent mastery from genuine mastery. Study Doctor reads the last fortnight
and separates genuine gaps from careless slips and pacing problems. The Profile Advisor judges university pathways
from the record.`;

    const rules =
      "You are Edu AI inside EduNexus, a school platform. Speak to the student directly, warmly and plainly. " +
      "Use ONLY the evidence given to you. Never invent a score, a paper or a topic. " +
      "If the evidence is thin, say so and tell them what to complete so you can help properly. " +
      "You are given the actual questions, answers and marker notes behind each score, so answer from those specifics " +
      "and name the exact sub-topics, question types or mistakes involved. Never ask the student to tell you what was on an " +
      "assessment you can already see. " +
      "Two or three short paragraphs at most. No bullet lists unless asked. " +
      "You know how EduNexus works, so never say a term like genome score is unfamiliar or ask the student to explain " +
      "the platform to you. Explain it yourself, using their own numbers.";

    let out: any;
    switch (task) {
      case "chat": {
        const ctx = topics.length
          ? topics.map(t => `${t.topic} (${t.subject || "—"}): ${t.score}% from ${t.evidence} pieces of evidence`).join("\n")
          : "No graded work recorded yet.";
        const clip = (v: unknown, n = 300) => String(v ?? "").replace(/\s+/g, " ").slice(0, n);

        /* The detail behind each piece of work: the actual questions, the
           actual answers, and why they were marked that way. Without this
           the model can only see a score and has to ask the student. */
        const detail = recent.slice(0, 14).map(a => {
          const m = a.meta ?? {};
          const head = `[${a.kind}] ${a.topic} — ${Math.round(Number(a.score))}% (${new Date(a.created_at).toDateString()})`;
          if (a.kind === "mirage") {
            const rows = (m.breakdown ?? []).map((b: any) =>
              `    level ${b.level} (${b.label}) scored ${Math.round(Number(b.score ?? 0))}%\n` +
              `      asked: ${clip(b.question, 220)}\n` +
              `      answered: ${clip(b.answer, 180) || "(blank)"}\n` +
              `      marker's note: ${clip(b.note, 200)}`).join("\n");
            return `${head}\n  apparent mastery ${m.apparent ?? "?"}%, genuine ${m.genuine ?? Math.round(Number(a.score))}%` +
                   (m.verdict ? `\n  verdict: ${clip(m.verdict, 400)}` : "") +
                   (m.root_cause ? `\n  root cause: ${clip(m.root_cause, 300)}` : "") +
                   (rows ? `\n${rows}` : "");
          }
          if (a.kind === "examlens") {
            return `${head}\n  cause: ${m.cause ?? "?"}\n  question: ${clip(m.question, 260)}\n` +
                   `  their answer: ${clip(m.answer, 200)}\n  verdict: ${clip(m.verdict, 260)}` +
                   (m.explanation ? `\n  why: ${clip(m.explanation, 400)}` : "");
          }
          if (a.kind === "lesson") {
            return `${head}\n  checkpoint: ${clip(m.question, 220)}\n` +
                   `  chose: ${clip(m.chosenText, 140)}${m.correctText ? ` / correct was: ${clip(m.correctText, 140)}` : ""}`;
          }
          return head;
        }).join("\n\n") || "none";
        const messages = [
          { role: "system", content: `${rules}\n${PLATFORM}\n\nStudent: ${profile?.full_name}. Class: ${profile?.grade ?? "unknown"}. Stated goal: ${profile?.goal ?? "none given"}.\nOverall genome score shown in their app: ${overall === null ? "none yet" : overall + "%"}\nTopic scores (weakest first):\n${ctx}\n\nWhat happened in each recent piece of work:\n${detail}` },
          ...(payload.history ?? []).slice(-6),
          { role: "user", content: String(payload.message ?? "") },
        ];
        out = { reply: await groq(messages), topics: topics.slice(0, 4), evidenceCount: recent.length };
        break;
      }
      case "checkpoint": {
        const messages = [
          { role: "system", content: `${rules} The student just answered a lesson checkpoint. In two or three sentences, say why their answer works or where the thinking went wrong, and name the underlying idea.` },
          { role: "user", content: `Topic: ${payload.topic}\nQuestion: ${payload.question}\nOptions: ${(payload.options ?? []).join(" | ")}\nThey chose: ${payload.chosen}\nCorrect answer: ${payload.correct}\nWere they right: ${payload.wasRight}` },
        ];
        out = { text: await groq(messages) };
        break;
      }
      case "generate_checkpoint": {
        const messages = [
          { role: "system", content: "You write one multiple-choice checkpoint for a school lesson. Return JSON only: {\"question\":string,\"options\":[string,string,string],\"answer\":0,\"explanation\":string}. The wrong options must be plausible misconceptions, not obviously silly. answer is the index of the correct option." },
          { role: "user", content: `Subject: ${payload.subject}\nLesson: ${payload.title}\nTopic: ${payload.topic}\nLesson text: ${(payload.body ?? "").slice(0, 3000)}` },
        ];
        out = asJson(await groq(messages, true));
        break;
      }
      case "generate_lesson": {
        const messages = [
          { role: "system", content: "You write clear lesson notes for A-level students. Plain prose and short paragraphs, 200 to 300 words, no headings, no markdown symbols. Include the key relationship or definition stated precisely." },
          { role: "user", content: `Subject: ${payload.subject}\nLesson title: ${payload.title}\nTopic: ${payload.topic}` },
        ];
        out = { body: await groq(messages) };
        break;
      }
      case "examlens": {
        const messages = [
          { role: "system", content: "You are ExamLens. You mark one exam answer and classify WHY marks were lost. Return JSON only: {\"score\":0-100,\"cause\":\"conceptual gap|method slip|arithmetic or units|misread the question|blank\",\"verdict\":string,\"explanation\":string,\"correct_working\":string,\"topic\":string}. verdict is one short sentence. explanation is two or three sentences naming the misconception. If the answer is fully correct, cause is \"none\"." },
          { role: "user", content: `Subject: ${payload.subject}\nTopic given by student: ${payload.topic}\nQuestion: ${payload.question}\nStudent answer: ${payload.answer}\nMark scheme or expected answer: ${payload.expected || "not provided — judge it yourself"}` },
        ];
        out = asJson(await groq(messages, true));
        break;
      }
      case "mirage_generate": {
        const messages = [
          { role: "system", content: "You are Mirage. You test whether mastery is genuine by asking the same idea at five increasing distances from how it is usually taught. Return JSON only: {\"questions\":[{\"level\":1,\"label\":\"Identical form\",\"question\":string,\"expected\":string}]}. Exactly five questions, levels 1 to 5, labels: Identical form, Reworded, New values, New context, Inverse. Each question must be answerable in one or two sentences without a calculator where possible." },
          { role: "user", content: `Subject: ${payload.subject}\nTopic: ${payload.topic}` },
        ];
        out = asJson(await groq(messages, true));
        break;
      }
      case "mirage_mark": {
        const messages = [
          { role: "system", content: "You mark short answers strictly but fairly. Return JSON only: {\"results\":[{\"level\":1,\"correct\":true,\"score\":0-100,\"note\":string}],\"verdict\":string,\"root_cause\":string}. score reflects partial credit. verdict explains, in two or three sentences, whether the mastery is genuine or pattern-matched, using the pattern across levels." },
          { role: "user", content: `Topic: ${payload.topic}\n` + (payload.answers ?? []).map((a: any) => `Level ${a.level} (${a.label})\nQ: ${a.question}\nExpected: ${a.expected}\nStudent: ${a.answer || "(blank)"}`).join("\n\n") },
        ];
        out = asJson(await groq(messages, true));
        break;
      }
      case "doctor": {
        const session = payload.session ?? [];
        const messages = [
          { role: "system", content: `${rules}\n${PLATFORM}\nYou are Study Doctor. Separate genuine knowledge gaps from careless slips and pacing problems, then give one prescription the student can start today. Return JSON only: {"findings":[{"kind":"gap|slip|pacing","title":string,"text":string}],"prescription":string}.` },
          { role: "user", content: `Recent work:\n` + session.map((a: any) => `${a.kind} · ${a.topic} · ${a.score}%${a.seconds ? ` · ${a.seconds}s` : ""}`).join("\n") + `\n\nTopic scores:\n` + topics.map(t => `${t.topic}: ${t.score}%`).join("\n") },
        ];
        out = asJson(await groq(messages, true));
        break;
      }
      case "advisor": {
        const messages = [
          { role: "system", content: `${rules}\n${PLATFORM}\nYou are the Profile Advisor. Judge fit from the record, not from what the student wishes. Return JSON only: {"matches":[{"name":string,"fit":0-100,"why":string}],"requirements":[{"title":string,"status":string,"met":boolean}],"todo":[{"title":string,"detail":string}],"blocking":string}. Three to five matches, strongest first.` },
          { role: "user", content: `Goal: ${profile?.goal ?? "not stated"}\nInterests: ${(profile?.interests ?? []).join(", ") || "not stated"}\nTopic scores:\n` + (topics.map(t => `${t.topic} (${t.subject}): ${t.score}%`).join("\n") || "no graded work yet") },
        ];
        out = asJson(await groq(messages, true));
        break;
      }
      case "video_transcript": {
        out = { transcript: await fetchCaptions(payload.url) };
        break;
      }
      case "summarise_video": {
        const t = String(payload.transcript || "").slice(0, 24000);
        if (!t) throw new Error("No transcript to read");
        const messages = [
          { role: "system", content: "You turn a lesson video transcript into study material for A-level students. Return JSON only: {\"summary\":string,\"key_points\":[string],\"notes\":string,\"checkpoint\":{\"question\":string,\"options\":[string,string,string],\"answer\":0,\"explanation\":string}}. summary is three or four sentences a student reads before watching. key_points is three to five short lines. notes is 150 to 250 words of plain prose covering what the video actually teaches, no headings. The checkpoint must test understanding of something said in the video, with wrong options that are real misconceptions." },
          { role: "user", content: `Subject: ${payload.subject}\nLesson: ${payload.title}\nTopic: ${payload.topic}\nTranscript:\n${t}` },
        ];
        out = asJson(await groq(messages, true));
        break;
      }
      default:
        return json({ error: `Unknown task: ${task}` }, 400);
    }
    return json(out);
  } catch (err) {
    return json({ error: String((err as Error).message ?? err) }, 500);
  }
});
