// functions/ride-chat.ts — one Durable Object per trip holding the rider ⇄ driver chat (v2).
// Messages are short, capped and auto-expire 24 hours after the last line. Translation happens on
// each reader's phone, so the server only stores the original text and its language.

import { DurableObject } from "cloudflare:workers";

const MAX_MESSAGES = 200;
const MAX_LENGTH = 300;
const TTL_MS = 24 * 60 * 60 * 1000;

type ChatMessage = {
  id: string;
  sender: "passenger" | "driver";
  original: string;
  language: "sw" | "en";
  sentAt: number;
};

export class RideChat extends DurableObject {
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env as never);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        sender TEXT NOT NULL,
        original TEXT NOT NULL,
        language TEXT NOT NULL,
        sent_at INTEGER NOT NULL,
        device TEXT
      )
    `);
  }

  override async fetch(request: Request): Promise<Response> {
    if (request.method === "GET") {
      this.ctx.storage.sql.exec("DELETE FROM messages WHERE sent_at < ?", Date.now() - TTL_MS);
      const rows = this.ctx.storage.sql
        .exec("SELECT id, sender, original, language, sent_at FROM messages ORDER BY sent_at ASC LIMIT ?", MAX_MESSAGES)
        .toArray();
      const messages: ChatMessage[] = rows.map((row) => ({
        id: String(row.id),
        sender: row.sender === "driver" ? "driver" : "passenger",
        original: String(row.original),
        language: row.language === "en" ? "en" : "sw",
        sentAt: Number(row.sent_at),
      }));
      return Response.json({ messages });
    }

    if (request.method === "POST") {
      let body: Partial<ChatMessage>;
      try {
        body = await request.json();
      } catch {
        return Response.json({ error: "invalid_json" }, { status: 400 });
      }
      const text = String(body.original ?? "").trim().slice(0, MAX_LENGTH);
      const id = String(body.id ?? "").slice(0, 64);
      if (!text || !id) return Response.json({ error: "missing_fields" }, { status: 400 });
      // Alarms aren't available here, so lines older than a day are pruned on each write.
      this.ctx.storage.sql.exec("DELETE FROM messages WHERE sent_at < ?", Date.now() - TTL_MS);
      const count = Number(this.ctx.storage.sql.exec("SELECT COUNT(*) AS n FROM messages").one().n);
      if (count >= MAX_MESSAGES) return Response.json({ error: "chat_full" }, { status: 429 });
      this.ctx.storage.sql.exec(
        "INSERT OR IGNORE INTO messages (id, sender, original, language, sent_at, device) VALUES (?, ?, ?, ?, ?, ?)",
        id,
        body.sender === "driver" ? "driver" : "passenger",
        text,
        body.language === "en" ? "en" : "sw",
        Date.now(),
        request.headers.get("X-Zuri-Device") ?? null,
      );
      return Response.json({ ok: true });
    }

    return Response.json({ error: "method_not_allowed" }, { status: 405 });
  }
}
