// functions/scenery-store.ts — pre-baked 3D scenery distribution (one catalogue per region).
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

  private metaText(key: string): string {
    return this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0]?.value ?? "";
  }
  private setMetaText(key: string, value: string): void {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", key, value);
  }

  /** A live catalogue locks keyless uploads, except that a set of the superseded ring format
   *  (coarse/medium/fine pieces, no whole-tile `-s-` scene piece) may be replaced once by a scene
   *  set; once a scene set is live the catalogue is locked for good. */
  private seedLocked(): boolean {
    const live = this.meta("live");
    if (live === 0) return false;
    const rows = this.ctx.storage.sql.exec<{ dir: string }>("SELECT dir FROM files WHERE generation = ?", live).toArray();
    const pieces = rows.filter((r) => r.dir.startsWith("piece-"));
    if (pieces.length === 0) return true;
    return pieces.some((r) => /-s-[0-9]+-[0-9]+$/.test(r.dir));
  }

  /** Seed uploads: one keyless contributor may fill an empty catalogue, holding a 45-minute token. */
  private seedError(url: URL, g: number): Response | null {
    const token = url.searchParams.get("seed");
    if (token === null) return null;
    if (this.seedLocked()) return Response.json({ error: "already_published" }, { status: 409 });
    if (token !== this.metaText("seedToken") || Date.now() > this.meta("seedExpiry") || g !== this.meta("upload")) {
      return Response.json({ error: "seed_expired" }, { status: 409 });
    }
    const row = this.ctx.storage.sql.exec<{ n: number; b: number }>(
      "SELECT COUNT(*) AS n, COALESCE(SUM(bytes), 0) AS b FROM files WHERE generation = ?", g).toArray()[0];
    if (Number(row?.n ?? 0) >= Number(url.searchParams.get("maxFiles") ?? 0) ||
        Number(row?.b ?? 0) >= Number(url.searchParams.get("maxBytes") ?? 0)) {
      return Response.json({ error: "seed_too_large" }, { status: 413 });
    }
    this.setMeta("seedActivity", Date.now());
    return null;
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const action = url.searchParams.get("action");

    if (request.method === "POST" && action === "check") {
      return this.seedError(url, Number(url.searchParams.get("g") ?? "0")) ?? Response.json({ ok: true });
    }

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
      const seeding = url.searchParams.get("seed") === "new";
      let token = "";
      if (seeding) {
        if (this.seedLocked()) return Response.json({ error: "already_published" }, { status: 409 });
        const idle = Date.now() - Math.max(this.meta("seedActivity"), this.meta("seedStarted"));
        if (this.metaText("seedToken") && Date.now() < this.meta("seedExpiry") && idle < 3 * 60 * 1000) {
          return Response.json({ error: "seed_in_progress" }, { status: 409 });
        }
        token = [...crypto.getRandomValues(new Uint8Array(16))].map((x) => x.toString(16).padStart(2, "0")).join("");
        this.setMetaText("seedToken", token);
        this.setMeta("seedExpiry", Date.now() + 45 * 60 * 1000);
        this.setMeta("seedStarted", Date.now());
      } else {
        this.setMetaText("seedToken", "");
      }
      const next = Math.max(this.meta("upload"), this.meta("live")) + 1;
      this.setMeta("upload", next);
      this.ctx.storage.sql.exec("DELETE FROM files WHERE generation = ?", next);
      return Response.json(seeding ? { generation: next, token } : { generation: next });
    }

    if (request.method === "POST" && action === "record") {
      const body = await request.json<CatalogFile & { g: number }>();
      const seed = this.seedError(url, body.g);
      if (seed) return seed;
      if (url.searchParams.has("seed")) {
        const used = Number(this.ctx.storage.sql.exec<{ b: number }>(
          "SELECT COALESCE(SUM(bytes), 0) AS b FROM files WHERE generation = ?", body.g).toArray()[0]?.b ?? 0);
        if (used + body.b > Number(url.searchParams.get("maxBytes") ?? 0)) {
          return Response.json({ error: "seed_too_large" }, { status: 413 });
        }
      }
      if (body.g !== this.meta("upload") || !validName(body.d) || !validName(body.f) || !/^[0-9a-f]{64}$/.test(body.s)) {
        return Response.json({ error: "stale_or_invalid" }, { status: 409 });
      }
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO files (generation, dir, file, bytes, sha) VALUES (?, ?, ?, ?, ?)",
        body.g, body.d, body.f, body.b, body.s,
      );
      return Response.json({ ok: true });
    }

    if (request.method === "POST" && action === "reset") {
      // Owner only (gated in index.ts): unpublishes the catalogue and drops any seed lock so the
      // next keyless contributor, or the owner, can publish a fresh set. Shards stay content-addressed.
      const previous = this.meta("live");
      this.setMeta("live", 0);
      this.setMeta("publishedAt", 0);
      this.setMetaText("seedToken", "");
      this.setMeta("seedExpiry", 0);
      this.setMeta("seedActivity", 0);
      this.setMeta("seedStarted", 0);
      this.ctx.storage.sql.exec("DELETE FROM files");
      return Response.json({ ok: true, unpublished: previous, seedCleared: true });
    }

    if (request.method === "POST" && action === "publish") {
      const body = await request.json<{ g: number; count: number }>();
      if (url.searchParams.has("seed")) {
        const token = url.searchParams.get("seed");
        if (this.seedLocked() || token !== this.metaText("seedToken") || Date.now() > this.meta("seedExpiry")) {
          return Response.json({ error: "seed_expired" }, { status: 409 });
        }
      }
      const upload = this.meta("upload");
      const count = Number(this.ctx.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM files WHERE generation = ?", upload).toArray()[0]?.n ?? 0);
      if (body.g !== upload || count === 0 || count !== body.count) {
        return Response.json({ error: "incomplete_upload", recorded: count }, { status: 409 });
      }
      const previous = this.meta("live");
      this.setMeta("live", upload);
      this.setMeta("publishedAt", Date.now());
      this.setMetaText("seedToken", "");
      // Keep only the live and immediately previous catalogue rows.
      this.ctx.storage.sql.exec("DELETE FROM files WHERE generation NOT IN (?, ?)", upload, previous);
      return Response.json({ ok: true, revision: upload, files: count });
    }
    return Response.json({ error: "not_found" }, { status: 404 });
  }
}
