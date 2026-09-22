// EduNexus AI service.
// Runs on Supabase Edge Functions. The Groq key lives here, never in the browser.
// Deploy:  supabase functions deploy ai
// Secret:  supabase secrets set GROQ_API_KEY=your_key

import { createClient } from "jsr:@supabase/supabase-js@2";

const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";
const MODEL = "openai/gpt-oss-120b";
const MODEL_VISION = "qwen/qwen3.8-27b"; // the only vision-capable model Groq currently hosts

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function groq(messages: unknown[], jsonMode = false, model = MODEL) {
  const key = Deno.env.get("GROQ_API_KEY");
  if (!key) throw new Error("GROQ_API_KEY is not set on the function");
  const res = await fetch(GROQ_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
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

    const rules =
      "You are Edu AI inside EduNexus, a school platform. Speak to the student directly, warmly and plainly. " +
      "Use ONLY the evidence given to you. Never invent a score, a paper or a topic. " +
      "If the evidence is thin, say so and tell them what to complete so you can help properly. " +
      "Two or three short paragraphs at most. No bullet lists unless asked.";

    let out: any;
    switch (task) {
      case "chat": {
        const ctx = topics.length
          ? topics.map(t => `${t.topic} (${t.subject || "—"}): ${t.score}% from ${t.evidence} pieces of evidence`).join("\n")
          : "No graded work recorded yet.";
        const last = recent.slice(0, 8).map(a => `${a.kind} on ${a.topic}: ${a.score}%`).join("; ") || "none";
        const messages = [
          { role: "system", content: `${rules}\n\nStudent: ${profile?.full_name}. Class: ${profile?.grade ?? "unknown"}. Stated goal: ${profile?.goal ?? "none given"}.\nTopic scores (weakest first):\n${ctx}\nMost recent work: ${last}` },
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
      case "examlens_ocr": {
        const images: string[] = (Array.isArray(payload.images) ? payload.images : [payload.image]).filter(Boolean);
        if (!images.length) return json({ error: "No image provided" }, 400);
        if (images.length > 3) return json({ error: "Send at most 3 photos" }, 400);
        const content = [
          { type: "text", text: "Transcribe the exam question and the student's own answer exactly as written in the photo(s). Do not solve, correct or improve anything — just read what is on the page. If a mark scheme is visible, transcribe that too." },
          ...images.map((url) => ({ type: "image_url", image_url: { url } })),
        ];
        const messages = [
          { role: "system", content: "You are an exact transcription tool for photographed exam pages. Return JSON only: {\"question\":string,\"answer\":string,\"expected\":string,\"subject_guess\":string,\"topic_guess\":string}. Use an empty string for anything not visible in the photo(s). Never invent working the student didn't write." },
          { role: "user", content },
        ];
        out = asJson(await groq(messages, true, MODEL_VISION));
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
          { role: "system", content: `${rules} You are Study Doctor. Separate genuine knowledge gaps from careless slips and pacing problems, then give one prescription the student can start today. Return JSON only: {"findings":[{"kind":"gap|slip|pacing","title":string,"text":string}],"prescription":string}.` },
          { role: "user", content: `Recent work:\n` + session.map((a: any) => `${a.kind} · ${a.topic} · ${a.score}%${a.seconds ? ` · ${a.seconds}s` : ""}`).join("\n") + `\n\nTopic scores:\n` + topics.map(t => `${t.topic}: ${t.score}%`).join("\n") },
        ];
        out = asJson(await groq(messages, true));
        break;
      }
      case "advisor": {
        const messages = [
          { role: "system", content: `${rules} You are the Profile Advisor. Judge fit from the record, not from what the student wishes. Return JSON only: {"matches":[{"name":string,"fit":0-100,"why":string}],"requirements":[{"title":string,"status":string,"met":boolean}],"todo":[{"title":string,"detail":string}],"blocking":string}. Three to five matches, strongest first.` },
          { role: "user", content: `Goal: ${profile?.goal ?? "not stated"}\nInterests: ${(profile?.interests ?? []).join(", ") || "not stated"}\nTopic scores:\n` + (topics.map(t => `${t.topic} (${t.subject}): ${t.score}%`).join("\n") || "no graded work yet") },
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
