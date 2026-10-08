// functions/scenery-store.ts — pre-baked Masaki 3D scenery distribution.
//
// A publisher (one device or simulator that prepared and optimized the region) uploads every
// package file. Each file is content-addressed by SHA-256 and verified here; clients download the
// published catalogue during preparation, verify every file again and install atomically.
// SceneryCatalog ("masaki") holds the file list; one SceneryShard per package directory holds the
// bytes in ≤1.5 MB rows (Durable Object rows are limited to 2 MB, storage to 1 GB per object).

import { DurableObject } from "cloudflare:workers";

const CHUNK = 1_500_000;
const MAX_FILE = 8 * 1024 * 1024;
const NAME = /^[A-Za-z0-9._-]{1,160}$/;

export async function sha256Hex(data: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function validName(value: string | null): value is string {
  return !!value && NAME.test(value) && value !== "." && value !== "..";
}

export class SceneryShard extends DurableObject {
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env as never);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS chunks (
        file TEXT NOT NULL,
        sha TEXT NOT NULL,
        part INTEGER NOT NULL,
        data BLOB NOT NULL,
        PRIMARY KEY (file, sha, part)
      )
    `);
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const file = url.searchParams.get("f");
    const sha = url.searchParams.get("s") ?? "";
    if (!validName(file) || !/^[0-9a-f]{64}$/.test(sha)) return Response.json({ error: "bad_name" }, { status: 400 });

    if (request.method === "PUT") {
      const body = await request.arrayBuffer();
      if (body.byteLength > MAX_FILE) return Response.json({ error: "too_large" }, { status: 413 });
      if ((await sha256Hex(body)) !== sha) return Response.json({ error: "checksum_mismatch" }, { status: 422 });
      this.ctx.storage.sql.exec("DELETE FROM chunks WHERE file = ? AND sha = ?", file, sha);
      for (let offset = 0, part = 0; offset < body.byteLength || part === 0; offset += CHUNK, part++) {
        this.ctx.storage.sql.exec(
          "INSERT INTO chunks (file, sha, part, data) VALUES (?, ?, ?, ?)",
          file, sha, part, body.slice(offset, Math.min(body.byteLength, offset + CHUNK)),
        );
        if (body.byteLength === 0) break;
      }
      return Response.json({ ok: true, bytes: body.byteLength });
    }

    if (request.method === "GET") {
      const rows = this.ctx.storage.sql
        .exec<{ data: ArrayBuffer }>("SELECT data FROM chunks WHERE file = ? AND sha = ? ORDER BY part ASC", file, sha)
        .toArray();
      if (rows.length === 0) return Response.json({ error: "not_found" }, { status: 404 });
      const total = rows.reduce((sum, row) => sum + row.data.byteLength, 0);
      const out = new Uint8Array(total);
      let offset = 0;
      for (const row of rows) { out.set(new Uint8Array(row.data), offset); offset += row.data.byteLength; }
      return new Response(out, {
        headers: {
          "Content-Type": "application/octet-stream",
          "Content-Length": String(total),
          // Content-addressed: safe to cache forever at the edge.
          "Cache-Control": "public, max-age=31536000, immutable",
        },
      });
    }
    return Response.json({ error: "method" }, { status: 405 });
  }
}

type CatalogFile = { d: string; f: string; b: number; s: string };

export class SceneryCatalog extends DurableObject {
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env as never);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS files (
        generation INTEGER NOT NULL,
        dir TEXT NOT NULL,
        file TEXT NOT NULL,
        bytes INTEGER NOT NULL,
        sha TEXT NOT NULL,
        PRIMARY KEY (generation, dir, file)
      );
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    `);
  }

  private meta(key: string): number {
    const row = this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0];
    return row ? Number(row.value) : 0;
  }
  private setMeta(key: string, value: number): void {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", key, String(value));
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const action = url.searchParams.get("action");

    if (request.method === "GET" && action === "catalog") {
      const live = this.meta("live");
      const files: CatalogFile[] = live === 0 ? [] : this.ctx.storage.sql
        .exec<{ dir: string; file: string; bytes: number; sha: string }>(
          "SELECT dir, file, bytes, sha FROM files WHERE generation = ? ORDER BY dir, file", live)
        .toArray()
        .map((r) => ({ d: r.dir, f: r.file, b: Number(r.bytes), s: r.sha }));
      return Response.json({ revision: live, publishedAt: this.meta("publishedAt"), files });
    }

    if (request.method === "POST" && action === "begin") {
      const next = Math.max(this.meta("upload"), this.meta("live")) + 1;
      this.setMeta("upload", next);
      this.ctx.storage.sql.exec("DELETE FROM files WHERE generation = ?", next);
      return Response.json({ generation: next });
    }

    if (request.method === "POST" && action === "record") {
      const body = await request.json<CatalogFile & { g: number }>();
      if (body.g !== this.meta("upload") || !validName(body.d) || !validName(body.f) || !/^[0-9a-f]{64}$/.test(body.s)) {
        return Response.json({ error: "stale_or_invalid" }, { status: 409 });
      }
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO files (generation, dir, file, bytes, sha) VALUES (?, ?, ?, ?, ?)",
        body.g, body.d, body.f, body.b, body.s,
      );
      return Response.json({ ok: true });
    }

    if (request.method === "POST" && action === "publish") {
      const body = await request.json<{ g: number; count: number }>();
      const upload = this.meta("upload");
      const count = Number(this.ctx.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM files WHERE generation = ?", upload).toArray()[0]?.n ?? 0);
      if (body.g !== upload || count === 0 || count !== body.count) {
        return Response.json({ error: "incomplete_upload", recorded: count }, { status: 409 });
      }
      const previous = this.meta("live");
      this.setMeta("live", upload);
      this.setMeta("publishedAt", Date.now());
      // Keep only the live and immediately previous catalogue rows.
      this.ctx.storage.sql.exec("DELETE FROM files WHERE generation NOT IN (?, ?)", upload, previous);
      return Response.json({ ok: true, revision: upload, files: count });
    }
    return Response.json({ error: "not_found" }, { status: 404 });
  }
}
