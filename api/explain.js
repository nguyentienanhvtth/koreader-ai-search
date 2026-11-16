// Vercel serverless function: POST /api/explain
// Explains a word/phrase in the context of a book passage, for Vietnamese
// learners of English, using DeepSeek. Request/response contract: see
// ../README.md (it matches the KOReader contextdict plugin).

const DEEPSEEK_URL = "https://api.deepseek.com/chat/completions";
const MAX_WORD = 120;
const MAX_CONTEXT = 1500;

const SYSTEM_PROMPT = `You are an English tutor for Vietnamese readers of English books.
The user selected a word (or phrase) while reading. Explain what it means IN THIS PASSAGE.

Rules:
- If the selected word is part of a larger expression in the sentence (phrasal verb, idiom, collocation, e.g. "grow" in "grow up", "bring" in "couldn't bring himself to"), explain the WHOLE expression and put its dictionary form in "lemma" (e.g. "grow up", "bring oneself to do something").
- Only the meaning used in this passage. Do not list unrelated meanings in the main fields.
- "meaning_en": simple English (CEFR B1 words), max 20 words.
- "meaning_vi": short natural Vietnamese meaning as used here, max 20 words.
- "sentence_vi": natural Vietnamese translation of the sentence containing the word.
- "explanation_vi": one short Vietnamese sentence on why this meaning fits here; "" if obvious.
- "part_of_speech": in English: noun, verb, adjective, adverb, phrasal verb, idiom, collocation, ...
- "cefr_level": A1, A2, B1, B2, C1 or C2 (level of the expression).
- "ipa": IPA of the lemma if it is a single word, else "".
- "other_meanings": up to 2 other common meanings, in Vietnamese, short. [] if none.
- "examples": exactly 1 new short example sentence using the same meaning, with Vietnamese translation.
- If no sentence/passage is given: explain the most common meaning, and set "sentence_vi" and "explanation_vi" to "" (never invent a sentence).

Reply with a single JSON object only, with exactly these keys:
{"word": "", "lemma": "", "part_of_speech": "", "cefr_level": "", "ipa": "", "meaning_en": "", "meaning_vi": "", "sentence_vi": "", "explanation_vi": "", "other_meanings": [], "examples": [{"en": "", "vi": ""}]}`;

const clip = (v, n) => (typeof v === "string" ? v.slice(0, n) : "");

function buildUserMessage(body) {
  const word = clip(body.word, MAX_WORD).trim();
  const lines = [`Selected: ${word}`];
  const sentence = clip(body.sentence, MAX_CONTEXT).trim();
  const before = clip(body.context_before, MAX_CONTEXT);
  const after = clip(body.context_after, MAX_CONTEXT);
  if (sentence) lines.push(`Sentence: ${sentence}`);
  if (before || after) {
    lines.push(`Passage: ${before}[[${clip(body.selected_text, MAX_WORD) || word}]]${after}`);
  }
  const book = body.book && typeof body.book === "object" ? body.book : {};
  if (book.title) lines.push(`Book: ${clip(book.title, 200)}${book.author ? " by " + clip(book.author, 200) : ""}`);
  return lines.join("\n");
}

async function readJsonBody(req) {
  if (req.body && typeof req.body === "object") return req.body; // Vercel already parsed it
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks).toString("utf8");
  return raw ? JSON.parse(raw) : {};
}

function send(res, status, obj) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.end(JSON.stringify(obj));
}

export default async function handler(req, res) {
  if (req.method !== "POST") return send(res, 405, { error: "Use POST" });

  // Shared secret so strangers cannot spend your DeepSeek credit.
  const token = process.env.APP_TOKEN;
  if (token && req.headers.authorization !== `Bearer ${token}`) {
    return send(res, 401, { error: "Sai API key" });
  }
  const apiKey = process.env.DEEPSEEK_API_KEY;
  if (!apiKey) return send(res, 500, { error: "Server chưa có DEEPSEEK_API_KEY" });

  let body;
  try {
    body = await readJsonBody(req);
  } catch {
    return send(res, 400, { error: "Body không phải JSON" });
  }
  if (!clip(body.word, MAX_WORD).trim()) return send(res, 400, { error: "Thiếu 'word'" });

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 25000);
  try {
    const r = await fetch(DEEPSEEK_URL, {
      method: "POST",
      signal: controller.signal,
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({
        model: process.env.DEEPSEEK_MODEL || "deepseek-chat",
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: buildUserMessage(body) },
        ],
        response_format: { type: "json_object" },
        temperature: 0.2,
        max_tokens: 700,
      }),
    });
    if (!r.ok) {
      const detail = (await r.text()).slice(0, 300);
      console.error("DeepSeek error", r.status, detail);
      return send(res, 502, { error: `DeepSeek lỗi ${r.status}` });
    }
    const data = await r.json();
    const content = data?.choices?.[0]?.message?.content || "";
    let result;
    try {
      result = JSON.parse(content);
    } catch {
      console.error("Non-JSON from model", content.slice(0, 300));
      return send(res, 502, { error: "AI trả về dữ liệu không hợp lệ, thử lại" });
    }
    if (!result.word) result.word = clip(body.word, MAX_WORD).trim();
    return send(res, 200, result);
  } catch (e) {
    const msg = e.name === "AbortError" ? "AI phản hồi quá lâu" : "Không gọi được DeepSeek";
    console.error(msg, e);
    return send(res, 504, { error: msg });
  } finally {
    clearTimeout(timer);
  }
}
