// functions/payment-ledger.ts — the single source of truth for Zuri mobile money payments.
//
// One Durable Object instance ("ledger") owns every payment row. It talks to ClickPesa when live
// keys are configured, and runs a faithful simulated payment network (approve / decline /
// wrong PIN / timeout) when they are not, so the app flow is identical in both modes.

import { DurableObject } from "cloudflare:workers";
import { ClickPesa, type ClickPesaEnv } from "./clickpesa";
import { WalletVerifier } from "./wallet-verifier";

export type PaymentStatus = "PENDING" | "SUCCESS" | "FAILED";
export type FailureReason = "declined" | "wrongPin" | "timeout" | "insufficientFunds" | "network" | "rejected";
export type Simulation = "interactive" | "auto";

type Row = {
  order_reference: string;
  device_id: string;
  phone: string;
  method: string;
  amount: number;
  purpose: string;
  status: PaymentStatus;
  reason: string | null;
  message: string | null;
  live: number;
  simulation: string | null;
  created_at: number;
  updated_at: number;
  last_polled_at: number;
};

/** Seconds a PIN prompt stays open before it expires, matching network USSD session limits. */
const PROMPT_TTL_MS = 60_000;
/** Simulated "auto" payments (auto top-up) approve after this delay, like a passenger typing a PIN. */
const AUTO_APPROVE_MS = 7_000;
/** Minimum spacing between live status queries to protect the ClickPesa daily API cap. */
const LIVE_POLL_SPACING_MS = 6_000;

export class PaymentLedger extends DurableObject<ClickPesaEnv> {
  private readonly clickpesa: ClickPesa;
  private readonly verifier: WalletVerifier;

  constructor(ctx: DurableObjectState, env: ClickPesaEnv) {
    super(ctx, env);
    this.clickpesa = new ClickPesa(env, ctx.storage);
    this.verifier = new WalletVerifier(ctx.storage, env, this.clickpesa);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS payments (
        order_reference TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        phone TEXT NOT NULL,
        method TEXT NOT NULL,
        amount INTEGER NOT NULL,
        purpose TEXT NOT NULL,
        status TEXT NOT NULL,
        reason TEXT,
        message TEXT,
        live INTEGER NOT NULL,
        simulation TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_polled_at INTEGER NOT NULL DEFAULT 0
      )
    `);
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    try {
      if (url.pathname === "/payments/config" && request.method === "GET") {
        return json({ live: this.clickpesa.isConfigured, provider: "clickpesa", minimum: 1000, maximum: 500000 });
      }
      if (url.pathname === "/wallets/lookup" && request.method === "POST") {
        return await this.verifier.lookup(request);
      }
      if (url.pathname === "/wallets/otp/send" && request.method === "POST") {
        return await this.verifier.send(request);
      }
      if (url.pathname === "/wallets/otp/verify" && request.method === "POST") {
        return await this.verifier.verify(request);
      }
      if (url.pathname === "/payments/collect" && request.method === "POST") {
        return await this.collect(request);
      }
      if (parts[0] === "payments" && parts.length === 3 && parts[2] === "simulate" && request.method === "POST") {
        return await this.simulate(parts[1], request);
      }
      if (parts[0] === "payments" && parts.length === 2 && request.method === "GET") {
        return await this.status(parts[1], request.headers.get("X-Zuri-Device") ?? "");
      }
      if (url.pathname === "/webhooks/clickpesa" && request.method === "POST") {
        return await this.webhook(request);
      }
      if (url.pathname === "/payouts/preview" && request.method === "POST") {
        return await this.payout(request, true);
      }
      if (url.pathname === "/payouts/create" && request.method === "POST") {
        return await this.payout(request, false);
      }
      return json({ error: "not_found" }, 404);
    } catch (error) {
      console.error("ledger error", error instanceof Error ? error.message : String(error));
      return json({ error: "server_error", message: "Payment service is unavailable. Try again." }, 500);
    }
  }

  // MARK: Collection (USSD push)

  private async collect(request: Request): Promise<Response> {
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    const deviceId = request.headers.get("X-Zuri-Device") ?? "";
    if (!body || deviceId.length < 8) return json({ error: "bad_request", message: "Missing payment details." }, 400);

    const amount = Math.round(Number(body.amount));
    const phone = normalisePhone(String(body.phone ?? ""));
    const method = String(body.method ?? "");
    const purpose = String(body.purpose ?? "topUp");
    const simulation: Simulation = body.simulation === "auto" ? "auto" : "interactive";

    const minimum = purpose === "ride" ? 100 : 1000;
    if (!Number.isFinite(amount) || amount < minimum || amount > 500000) {
      return json({ error: "invalid_amount", message: `Amount must be between TZS ${minimum.toLocaleString("en-US")} and TZS 500,000.` }, 400);
    }
    if (!phone) return json({ error: "invalid_phone", message: "Enter a valid Tanzanian mobile number." }, 400);
    if (!["mpesa", "mixx", "airtel", "halopesa"].includes(method)) {
      return json({ error: "invalid_method", message: "Choose a mobile money wallet." }, 400);
    }
    // Only numbers this device proved it owns (SMS code) can be charged.
    if (!this.verifier.isVerified(deviceId, phone, method)) {
      return json({ error: "unverified_wallet", message: "Verify this number with an SMS code before paying from it." }, 403);
    }
    const network = networkForPhone(phone);
    if (network && network !== method) {
      const names: Record<string, string> = { mpesa: "M-Pesa", mixx: "Mixx by Yas", airtel: "Airtel Money", halopesa: "HaloPesa" };
      return json({ error: "network_mismatch", message: `This number is on ${names[network]}, not ${names[method]}. Link a ${names[method]} number or choose ${names[network]}.` }, 400);
    }
    if (!["topUp", "autoTopUp", "ride"].includes(purpose)) {
      return json({ error: "invalid_purpose", message: "Unknown payment type." }, 400);
    }

    const orderReference = makeOrderReference();
    const now = Date.now();
    const live = this.clickpesa.isConfigured;

    if (live) {
      const preview = await this.clickpesa.previewUssdPush({ amount, phone, orderReference });
      if (!preview.ok) return json({ error: "preview_failed", message: preview.message }, 422);
      const initiated = await this.clickpesa.initiateUssdPush({ amount, phone, orderReference });
      if (!initiated.ok) return json({ error: "initiate_failed", message: initiated.message }, 422);
    }

    this.ctx.storage.sql.exec(
      `INSERT INTO payments (order_reference, device_id, phone, method, amount, purpose, status, reason, message, live, simulation, created_at, updated_at, last_polled_at)
       VALUES (?, ?, ?, ?, ?, ?, 'PENDING', NULL, NULL, ?, ?, ?, ?, 0)`,
      orderReference, deviceId, phone, method, amount, purpose, live ? 1 : 0, live ? null : simulation, now, now,
    );
    console.log("collect", { orderReference, method, amount, purpose, live, prefix: phone.slice(3, 5) });
    return json(this.present(this.row(orderReference)!));
  }

  private async status(orderReference: string, deviceId: string): Promise<Response> {
    let row = this.row(orderReference);
    if (!row || row.device_id !== deviceId) return json({ error: "not_found", message: "Payment not found." }, 404);
    row = await this.advance(row);
    return json(this.present(row));
  }

  /** Moves a pending payment forward: expiry, simulated auto-approval, or a spaced live status query. */
  private async advance(row: Row): Promise<Row> {
    if (row.status !== "PENDING") return row;
    const now = Date.now();
    if (!row.live) {
      if (row.simulation === "auto" && now - row.created_at >= AUTO_APPROVE_MS) {
        return this.settle(row.order_reference, "SUCCESS", null, "Approved");
      }
      if (now - row.created_at >= PROMPT_TTL_MS) {
        return this.settle(row.order_reference, "FAILED", "timeout", "The PIN prompt expired.");
      }
      return row;
    }
    if (now - row.last_polled_at < LIVE_POLL_SPACING_MS) return row;
    this.ctx.storage.sql.exec("UPDATE payments SET last_polled_at = ? WHERE order_reference = ?", now, row.order_reference);
    const remote = await this.clickpesa.queryPayment(row.order_reference);
    if (remote?.status === "SUCCESS" || remote?.status === "SETTLED") {
      return this.settle(row.order_reference, "SUCCESS", null, remote.message ?? "Approved");
    }
    if (remote?.status === "FAILED") {
      return this.settle(row.order_reference, "FAILED", classify(remote.message), remote.message ?? "Payment failed.");
    }
    if (now - row.created_at >= PROMPT_TTL_MS * 2) {
      return this.settle(row.order_reference, "FAILED", "timeout", "No approval was received in time.");
    }
    return this.row(row.order_reference)!;
  }

  /** Test-mode stand-in for the passenger acting on the network's PIN prompt. */
  private async simulate(orderReference: string, request: Request): Promise<Response> {
    const row = this.row(orderReference);
    const deviceId = request.headers.get("X-Zuri-Device") ?? "";
    if (!row || row.device_id !== deviceId) return json({ error: "not_found", message: "Payment not found." }, 404);
    if (row.live) return json({ error: "live_payment", message: "Live payments are approved on the phone." }, 409);
    const body = (await request.json().catch(() => ({}))) as { action?: string; pin?: string };
    const advanced = await this.advance(row);
    if (advanced.status !== "PENDING") return json(this.present(advanced));
    switch (body.action) {
      case "approve": {
        const pin = String(body.pin ?? "");
        if (!/^\d{4}$/.test(pin) || pin === "0000") {
          return json(this.present(this.settle(orderReference, "FAILED", "wrongPin", "Wrong PIN entered.")));
        }
        return json(this.present(this.settle(orderReference, "SUCCESS", null, "Approved")));
      }
      case "decline":
        return json(this.present(this.settle(orderReference, "FAILED", "declined", "Cancelled on the phone.")));
      case "insufficient":
        return json(this.present(this.settle(orderReference, "FAILED", "insufficientFunds", "Not enough money in the wallet.")));
      default:
        return json({ error: "bad_action", message: "Unknown action." }, 400);
    }
  }

  // MARK: Webhook

  private async webhook(request: Request): Promise<Response> {
    const raw = await request.text();
    let payload: { event?: string; data?: Record<string, unknown>; checksum?: string };
    try {
      payload = JSON.parse(raw);
    } catch {
      return json({ error: "bad_json" }, 400);
    }
    if (!(await this.clickpesa.verifyWebhook(payload as Record<string, unknown>))) {
      console.warn("webhook rejected: checksum mismatch");
      return json({ error: "invalid_checksum" }, 401);
    }
    const data = payload.data ?? {};
    const orderReference = String(data.orderReference ?? "");
    const row = this.row(orderReference);
    if (!row) return json({ ok: true, ignored: true });
    if (payload.event === "PAYMENT RECEIVED") {
      this.settle(orderReference, "SUCCESS", null, String(data.message ?? "Approved"));
    } else if (payload.event === "PAYMENT FAILED") {
      const message = String(data.message ?? "Payment failed.");
      this.settle(orderReference, "FAILED", classify(message), message);
    }
    console.log("webhook", { event: payload.event, orderReference });
    return json({ ok: true });
  }

  // MARK: Payouts (ready for Zuri Driver)

  private async payout(request: Request, previewOnly: boolean): Promise<Response> {
    const adminKey = this.env.ZURI_ADMIN_KEY;
    if (!adminKey || request.headers.get("X-Zuri-Admin") !== adminKey) {
      return json({ error: "forbidden", message: "Payouts require the operator key." }, 403);
    }
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    const amount = Math.round(Number(body?.amount));
    const phone = normalisePhone(String(body?.phone ?? ""));
    if (!phone || !Number.isFinite(amount) || amount < 1000) return json({ error: "bad_request" }, 400);
    if (!this.clickpesa.isConfigured) {
      return json({ live: false, status: previewOnly ? "PREVIEW_OK" : "SIMULATED", amount, phone });
    }
    const orderReference = String(body?.orderReference ?? makeOrderReference());
    const result = previewOnly
      ? await this.clickpesa.previewPayout({ amount, phone, orderReference })
      : await this.clickpesa.createPayout({ amount, phone, orderReference });
    return json({ live: true, orderReference, ...result }, result.ok ? 200 : 422);
  }

  // MARK: Rows

  private row(orderReference: string): Row | null {
    const rows = this.ctx.storage.sql
      .exec<Row>("SELECT * FROM payments WHERE order_reference = ?", orderReference)
      .toArray();
    return rows[0] ?? null;
  }

  /** Terminal transitions are one-way: a settled payment is never reopened or double-credited. */
  private settle(orderReference: string, status: PaymentStatus, reason: FailureReason | null, message: string): Row {
    this.ctx.storage.sql.exec(
      "UPDATE payments SET status = ?, reason = ?, message = ?, updated_at = ? WHERE order_reference = ? AND status = 'PENDING'",
      status, reason, message, Date.now(), orderReference,
    );
    return this.row(orderReference)!;
  }

  private present(row: Row) {
    return {
      orderReference: row.order_reference,
      status: row.status,
      reason: row.reason,
      message: row.message,
      amount: row.amount,
      method: row.method,
      purpose: row.purpose,
      live: row.live === 1,
      expiresAt: new Date(row.created_at + PROMPT_TTL_MS).toISOString(),
    };
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

/** Accepts +255 7XX…, 07XX…, 7XX… and returns 2557XXXXXXXX, or "" when invalid. */
export function normalisePhone(input: string): string {
  const digits = input.replace(/\D/g, "");
  let national = digits;
  if (national.startsWith("255")) national = national.slice(3);
  if (national.startsWith("0")) national = national.slice(1);
  if (!/^[67]\d{8}$/.test(national)) return "";
  return "255" + national;
}

/** Maps a 2557XXXXXXXX number to its mobile money network by prefix, or null when unknown. */
export function networkForPhone(phone: string): string | null {
  const prefix = phone.slice(3, 5);
  if (["65", "67", "71", "77"].includes(prefix)) return "mixx";
  if (["74", "75", "76"].includes(prefix)) return "mpesa";
  if (["68", "69", "78"].includes(prefix)) return "airtel";
  if (["61", "62"].includes(prefix)) return "halopesa";
  return null;
}

/** Alphanumeric, ≤20 chars (mobile money provider limit). */
export function makeOrderReference(): string {
  const time = Date.now().toString(36).toUpperCase();
  const random = crypto.getRandomValues(new Uint8Array(6));
  const tail = Array.from(random, (b) => (b % 36).toString(36)).join("").toUpperCase();
  return ("ZR" + time + tail).slice(0, 20);
}

function classify(message: string | undefined): FailureReason {
  const text = (message ?? "").toLowerCase();
  if (text.includes("pin")) return "wrongPin";
  if (text.includes("insufficient") || text.includes("balance")) return "insufficientFunds";
  if (text.includes("timeout") || text.includes("expired") || text.includes("timed out")) return "timeout";
  if (text.includes("cancel") || text.includes("declin") || text.includes("reject")) return "declined";
  return "rejected";
}
