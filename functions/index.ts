// functions/index.ts — Zuri backend entrypoint.
//
// Every payment route is forwarded to the single PaymentLedger Durable Object, which owns the
// ClickPesa credentials, the payment rows and the simulator used before live keys exist.

export { PaymentLedger } from "./payment-ledger";
export { AccountStore } from "./account-store";
export { RideChat } from "./ride-chat";
export { SceneryCatalog, SceneryShard } from "./scenery-store";
import { validName } from "./scenery-store";

type Env = { DO: Fetcher; SCENERY_PUBLISH_KEY?: string };

function dispatch(env: Env, url: string, init: RequestInit, cls: string, id: string): Promise<Response> {
  const wrapped = new Request(url, init);
  wrapped.headers.set("X-Rork-DO-Class", cls);
  wrapped.headers.set("X-Rork-DO-Id", id);
  return env.DO.fetch(wrapped);
}

function withCors(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS)) headers.set(key, value);
  return new Response(response.body, { status: response.status, headers });
}

// "harbour-z1" holds compact ZPK1 stream packages (one `zpk-<package>/package.zpk` per package),
// about a quarter of the size of the per-file format-2 packages in "harbour".
// "harbour-z2" holds finished, GPU-ready view pieces (one `piece-<tile>-<ring>-<col>-<row>/piece.bin`
// each): a phone bakes the harbour once and uploads them; viewers stream only what the camera sees.
const SCENERY_REGIONS = new Set(["masaki", "harbour", "golf", "harbour-z1", "harbour-z2"]);
/** Streamed regions the service seeds itself: any phone that has prepared the region may fill an
 *  EMPTY catalogue once, without a key. Only packages for these tiles are accepted; once live the
 *  region is locked and only the owner key can replace it. */
const HARBOUR_TILES = ["16-39919-34012", "16-39920-34012"];
const SEED_TILES: Record<string, string[]> = { harbour: HARBOUR_TILES, "harbour-z1": HARBOUR_TILES, "harbour-z2": HARBOUR_TILES };
const SEED_MAX_BYTES = 200 * 1024 * 1024;
const SEED_MAX_FILES = 400;

function seedDirectoryAllowed(region: string, d: string): boolean {
  const tiles = SEED_TILES[region];
  if (!tiles) return false;
  if (region === "harbour-z2") {
    // piece-<z>-<x>-<y>-<c|m|f|s>-<col>-<row>: one coarse, four medium, up to 100 fine pieces, or one
    // whole-tile stylised scene piece per tile.
    return tiles.some((t) => new RegExp(`^piece-${t}-[cmfs]-[0-9]{1,2}-[0-9]{1,2}$`).test(d));
  }
  if (!(d.startsWith("v") || d.startsWith("visual-") || d.startsWith("lod-") || d.startsWith("zpk-v"))) return false;
  return tiles.some((t) => d.includes(`-${t}-`) || d.endsWith(`-${t}`));
}

/** Pre-baked scenery per region: public reads, publish-key-protected writes. Package directory
 *  names carry the tile address, so shards are shared; each region has its own catalogue. */
async function scenery(request: Request, env: Env, url: URL): Promise<Response> {
  const base = `${url.origin}/scenery-internal`;
  const region = url.searchParams.get("region") ?? "masaki";
  if (!SCENERY_REGIONS.has(region)) return Response.json({ error: "bad_region" }, { status: 400 });
  if (request.method === "GET" && url.pathname === "/scenery/catalog") {
    return dispatch(env, `${base}?action=catalog`, { method: "GET" }, "SceneryCatalog", region);
  }
  if (request.method === "GET" && url.pathname === "/scenery/file") {
    const d = url.searchParams.get("d"), f = url.searchParams.get("f"), s = url.searchParams.get("s") ?? "";
    if (!validName(d) || !validName(f)) return Response.json({ error: "bad_name" }, { status: 400 });
    const res = await dispatch(env, `${base}?f=${encodeURIComponent(f)}&s=${encodeURIComponent(s)}`, { method: "GET" }, "SceneryShard", d);
    if (res.status !== 200 || !f!.endsWith(".json")) return res;
    // Manifests are text and shrink ~7× in transit: a text content type lets the edge gzip them;
    // the client decodes transparently and checks the SHA-256 of the original bytes.
    return new Response(res.body, {
      status: 200,
      headers: { "Content-Type": "application/json", "Cache-Control": res.headers.get("Cache-Control") ?? "public, max-age=31536000, immutable" },
    });
  }
  const key = env.SCENERY_PUBLISH_KEY;
  const owner = !!key && request.headers.get("X-Zuri-Scenery-Key") === key;
  const seedToken = request.headers.get("X-Zuri-Upload-Token") ?? "";
  if (!owner) {
    if (!SEED_TILES[region]) return Response.json({ error: "forbidden" }, { status: 403 });
    const isBegin = request.method === "POST" && url.pathname === "/scenery/begin";
    if (url.pathname === "/scenery/reset") {
      // Owner-only route; reports only whether a key is configured, never its value.
      return Response.json({ error: "forbidden", keyConfigured: !!key, keyLength: key?.length ?? 0 }, { status: 403 });
    }
    if (!isBegin && !/^[0-9a-f]{32}$/.test(seedToken)) return Response.json({ error: "forbidden" }, { status: 403 });
    if (request.method === "PUT" && url.pathname === "/scenery/file" && !seedDirectoryAllowed(region, url.searchParams.get("d") ?? "")) {
      return Response.json({ error: "tile_not_in_region" }, { status: 403 });
    }
  }
  const seedQuery = owner ? "" : `&seed=${seedToken}&maxBytes=${SEED_MAX_BYTES}&maxFiles=${SEED_MAX_FILES}`;
  if (request.method === "POST" && url.pathname === "/scenery/begin") {
    return dispatch(env, `${base}?action=begin${owner ? "" : "&seed=new"}`, { method: "POST" }, "SceneryCatalog", region);
  }
  if (request.method === "PUT" && url.pathname === "/scenery/file") {
    const d = url.searchParams.get("d"), f = url.searchParams.get("f"), s = url.searchParams.get("s") ?? "";
    const g = Number(url.searchParams.get("g") ?? "0");
    if (!validName(d) || !validName(f)) return Response.json({ error: "bad_name" }, { status: 400 });
    if (!owner) {
      const check = await dispatch(env, `${base}?action=check&g=${g}${seedQuery}`, { method: "POST" }, "SceneryCatalog", region);
      if (!check.ok) return check;
    }
    const body = await request.arrayBuffer();
    const stored = await dispatch(env, `${base}?f=${encodeURIComponent(f)}&s=${encodeURIComponent(s)}`, { method: "PUT", body }, "SceneryShard", d);
    if (!stored.ok) return stored;
    return dispatch(env, `${base}?action=record${seedQuery}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ g, d, f, b: body.byteLength, s }),
    }, "SceneryCatalog", region);
  }
  // Owner only: unpublishes the catalogue and drops any seed lock so a fresh set can be published.
  if (request.method === "POST" && url.pathname === "/scenery/reset") {
    if (!owner) return Response.json({ error: "forbidden" }, { status: 403 });
    return dispatch(env, `${base}?action=reset`, { method: "POST" }, "SceneryCatalog", region);
  }
  if (request.method === "POST" && url.pathname === "/scenery/publish") {
    return dispatch(env, `${base}?action=publish${seedQuery}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: await request.text(),
    }, "SceneryCatalog", region);
  }
  return Response.json({ error: "not_found" }, { status: 404 });
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Zuri-Device, X-Zuri-Admin, X-Zuri-Scenery-Key, X-Zuri-Upload-Token",
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    const url = new URL(request.url);

    if (url.pathname === "/ping") {
      return Response.json({ ok: true, service: "zuri", now: new Date().toISOString() }, { headers: CORS });
    }

    if (url.pathname.startsWith("/scenery/")) {
      return withCors(await scenery(request, env, url));
    }

    if (url.pathname.startsWith("/payments") || url.pathname.startsWith("/payouts") || url.pathname.startsWith("/wallets") || url.pathname === "/webhooks/clickpesa") {
      const wrapped = new Request(request.url, request);
      wrapped.headers.set("X-Rork-DO-Class", "PaymentLedger");
      wrapped.headers.set("X-Rork-DO-Id", "ledger");
      const response = await env.DO.fetch(wrapped);
      const headers = new Headers(response.headers);
      for (const [key, value] of Object.entries(CORS)) headers.set(key, value);
      return new Response(response.body, { status: response.status, headers });
    }

    // /chat/<tripId> — rider ⇄ driver messages for one trip.
    const chatMatch = url.pathname.match(/^\/chat\/([A-Za-z0-9_-]{4,64})$/);
    if (chatMatch) {
      const wrapped = new Request(request.url, request);
      wrapped.headers.set("X-Rork-DO-Class", "RideChat");
      wrapped.headers.set("X-Rork-DO-Id", `chat-${chatMatch[1]}`);
      const response = await env.DO.fetch(wrapped);
      const headers = new Headers(response.headers);
      for (const [key, value] of Object.entries(CORS)) headers.set(key, value);
      return new Response(response.body, { status: response.status, headers });
    }

    if (url.pathname === "/account") {
      // The platform verifies the Rork Auth bearer token and stamps X-Rork-User-* only when it is valid.
      const userId = request.headers.get("X-Rork-User-Id");
      if (!userId) return Response.json({ error: "sign_in_required" }, { status: 401, headers: CORS });
      const wrapped = new Request(request.url, request);
      wrapped.headers.set("X-Rork-DO-Class", "AccountStore");
      wrapped.headers.set("X-Rork-DO-Id", userId);
      wrapped.headers.set("X-Zuri-User", userId);
      wrapped.headers.set("X-Zuri-Email", request.headers.get("X-Rork-User-Email") ?? "");
      const response = await env.DO.fetch(wrapped);
      const headers = new Headers(response.headers);
      for (const [key, value] of Object.entries(CORS)) headers.set(key, value);
      return new Response(response.body, { status: response.status, headers });
    }

    return Response.json({ error: "not_found" }, { status: 404, headers: CORS });
  },
} satisfies ExportedHandler<Env>;
