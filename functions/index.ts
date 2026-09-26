// functions/index.ts — Zuri backend entrypoint.
//
// Every payment route is forwarded to the single PaymentLedger Durable Object, which owns the
// ClickPesa credentials, the payment rows and the simulator used before live keys exist.

export { PaymentLedger } from "./payment-ledger";
export { AccountStore } from "./account-store";
export { RideChat } from "./ride-chat";

type Env = { DO: Fetcher };

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Zuri-Device, X-Zuri-Admin",
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    const url = new URL(request.url);

    if (url.pathname === "/ping") {
      return Response.json({ ok: true, service: "zuri", now: new Date().toISOString() }, { headers: CORS });
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
