// functions/account-store.ts — one Durable Object instance per signed-in passenger (keyed by the
// verified Rork Auth user id). Holds their profile and saved app data as a single JSON document.

import { DurableObject } from "cloudflare:workers";

const MAX_BYTES = 512 * 1024;

export class AccountStore extends DurableObject {
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env as never);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS account (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        user_id TEXT NOT NULL,
        email TEXT,
        data TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    `);
  }

  override async fetch(request: Request): Promise<Response> {
    const userId = request.headers.get("X-Zuri-User") ?? "";
    if (!userId || userId !== this.ctx.id.name) return json({ error: "forbidden" }, 403);

    if (request.method === "GET") {
      const row = this.ctx.storage.sql.exec("SELECT data, updated_at FROM account WHERE id = 1").toArray()[0];
      if (!row) return json({ error: "not_found" }, 404);
      return json({ data: JSON.parse(String(row.data)), updatedAt: new Date(Number(row.updated_at)).toISOString() });
    }

    if (request.method === "PUT") {
      const text = await request.text();
      if (text.length > MAX_BYTES) return json({ error: "too_large" }, 413);
      let body: { data?: unknown };
      try {
        body = JSON.parse(text);
      } catch {
        return json({ error: "invalid_json" }, 400);
      }
      if (!body.data || typeof body.data !== "object") return json({ error: "missing_data" }, 400);
      const now = Date.now();
      this.ctx.storage.sql.exec(
        `INSERT INTO account (id, user_id, email, data, created_at, updated_at) VALUES (1, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET data = excluded.data, email = excluded.email, updated_at = excluded.updated_at`,
        userId,
        request.headers.get("X-Zuri-Email") ?? null,
        JSON.stringify(body.data),
        now,
        now,
      );
      return json({ ok: true, updatedAt: new Date(now).toISOString() });
    }

    if (request.method === "DELETE") {
      this.ctx.storage.sql.exec("DELETE FROM account");
      return json({ ok: true });
    }

    return json({ error: "method_not_allowed" }, 405);
  }
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}
