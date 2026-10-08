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

/** Pre-baked Masaki scenery: public reads, publish-key-protected writes. */
async function scenery(request: Request, env: Env, url: URL): Promise<Response> {
  const base = `${url.origin}/scenery-internal`;
  if (request.method === "GET" && url.pathname === "/scenery/catalog") {
    return dispatch(env, `${base}?action=catalog`, { method: "GET" }, "SceneryCatalog", "masaki");
  }
  if (request.method === "GET" && url.pathname === "/scenery/file") {
    const d = url.searchParams.get("d"), f = url.searchParams.get("f"), s = url.searchParams.get("s") ?? "";
    if (!validName(d) || !validName(f)) return Response.json({ error: "bad_name" }, { status: 400 });
    return dispatch(env, `${base}?f=${encodeURIComponent(f)}&s=${encodeURIComponent(s)}`, { method: "GET" }, "SceneryShard", d);
  }
  const key = env.SCENERY_PUBLISH_KEY;
  if (!key || request.headers.get("X-Zuri-Scenery-Key") !== key) {
    return Response.json({ error: key ? "forbidden" : "publishing_not_configured" }, { status: 403 });
  }
  if (request.method === "POST" && url.pathname === "/scenery/begin") {
    return dispatch(env, `${base}?action=begin`, { method: "POST" }, "SceneryCatalog", "masaki");
  }
  if (request.method === "PUT" && url.pathname === "/scenery/file") {
    const d = url.searchParams.get("d"), f = url.searchParams.get("f"), s = url.searchParams.get("s") ?? "";
    const g = Number(url.searchParams.get("g") ?? "0");
    if (!validName(d) || !validName(f)) return Response.json({ error: "bad_name" }, { status: 400 });
    const body = await request.arrayBuffer();
    const stored = await dispatch(env, `${base}?f=${encodeURIComponent(f)}&s=${encodeURIComponent(s)}`, { method: "PUT", body }, "SceneryShard", d);
    if (!stored.ok) return stored;
    return dispatch(env, `${base}?action=record`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ g, d, f, b: body.byteLength, s }),
    }, "SceneryCatalog", "masaki");
  }
  if (request.method === "POST" && url.pathname === "/scenery/publish") {
    return dispatch(env, `${base}?action=publish`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: await request.text(),
    }, "SceneryCatalog", "masaki");
  }
  return Response.json({ error: "not_found" }, { status: 404 });
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Zuri-Device, X-Zuri-Admin, X-Zuri-Scenery-Key",
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
