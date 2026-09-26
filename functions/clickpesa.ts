// functions/clickpesa.ts — thin, typed client for the ClickPesa third-party API.
//
// Keys live only in the project envs (CLICKPESA_CLIENT_ID / CLICKPESA_API_KEY, optional
// CLICKPESA_CHECKSUM_KEY). ClickPesa has no sandbox: live keys move real money, so the ledger
// falls back to its simulator whenever these are absent.

const BASE_URL = "https://api.clickpesa.com/third-parties";

export type ClickPesaEnv = {
  DO: Fetcher;
  CLICKPESA_CLIENT_ID?: string;
  CLICKPESA_API_KEY?: string;
  CLICKPESA_CHECKSUM_KEY?: string;
  ZURI_ADMIN_KEY?: string;
  BEEM_API_KEY?: string;
  BEEM_SECRET_KEY?: string;
  BEEM_SENDER_ID?: string;
};

export type SenderDetails = { accountName?: string; accountNumber?: string; accountProvider?: string };

type Result = { ok: true; data: unknown } | { ok: false; message: string };
type RemotePayment = { status?: string; message?: string };

export class ClickPesa {
  constructor(
    private readonly env: ClickPesaEnv,
    private readonly storage: DurableObjectStorage,
  ) {}

  get isConfigured(): boolean {
    return Boolean(this.env.CLICKPESA_CLIENT_ID && this.env.CLICKPESA_API_KEY);
  }

  previewUssdPush(input: { amount: number; phone: string; orderReference: string }): Promise<Result> {
    return this.post("/payments/preview-ussd-push-request", {
      amount: String(input.amount),
      currency: "TZS",
      orderReference: input.orderReference,
      phoneNumber: input.phone,
    });
  }

  initiateUssdPush(input: { amount: number; phone: string; orderReference: string }): Promise<Result> {
    return this.post("/payments/initiate-ussd-push-request", {
      amount: String(input.amount),
      currency: "TZS",
      orderReference: input.orderReference,
      phoneNumber: input.phone,
    });
  }

  /**
   * Read-only: previews a TZS 1,000 push with sender details to learn the number's real network and
   * registered name. No PIN prompt is sent and no money moves.
   */
  async senderDetails(phone: string): Promise<SenderDetails | null> {
    const random = Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => (b % 36).toString(36)).join("").toUpperCase();
    const result = await this.post("/payments/preview-ussd-push-request", {
      amount: "1000",
      currency: "TZS",
      orderReference: ("ZL" + Date.now().toString(36).toUpperCase() + random).slice(0, 20),
      phoneNumber: phone,
      fetchSenderDetails: true,
    });
    if (!result.ok) return null;
    const sender = (result.data as { sender?: SenderDetails } | null)?.sender;
    return sender ?? null;
  }

  async queryPayment(orderReference: string): Promise<RemotePayment | null> {
    const token = await this.token();
    if (!token) return null;
    const response = await fetch(`${BASE_URL}/payments/${encodeURIComponent(orderReference)}`, {
      headers: { Authorization: token },
    });
    if (response.status === 401) await this.storage.delete("clickpesa.token");
    if (!response.ok) return null;
    const rows = (await response.json().catch(() => [])) as RemotePayment[];
    return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
  }

  previewPayout(input: { amount: number; phone: string; orderReference: string }): Promise<Result> {
    return this.post("/payouts/preview-mobile-money-payout", {
      amount: input.amount,
      currency: "TZS",
      orderReference: input.orderReference,
      phoneNumber: input.phone,
    });
  }

  createPayout(input: { amount: number; phone: string; orderReference: string }): Promise<Result> {
    return this.post("/payouts/create-mobile-money-payout", {
      amount: input.amount,
      currency: "TZS",
      orderReference: input.orderReference,
      phoneNumber: input.phone,
    });
  }

  /** Webhooks are signed with the same canonical-JSON HMAC as requests; unsigned is accepted only when no key is set. */
  async verifyWebhook(payload: Record<string, unknown>): Promise<boolean> {
    const key = this.env.CLICKPESA_CHECKSUM_KEY;
    if (!key) return true;
    const provided = typeof payload.checksum === "string" ? payload.checksum : "";
    const { checksum: _checksum, checksumMethod: _method, ...rest } = payload;
    const expected = await checksum(key, rest);
    return timingSafeEqual(provided.toLowerCase(), expected);
  }

  // MARK: Transport

  private async post(path: string, body: Record<string, unknown>): Promise<Result> {
    const token = await this.token();
    if (!token) return { ok: false, message: "Payment provider credentials were rejected." };
    const payload: Record<string, unknown> = { ...body };
    if (this.env.CLICKPESA_CHECKSUM_KEY) payload.checksum = await checksum(this.env.CLICKPESA_CHECKSUM_KEY, body);
    const response = await fetch(BASE_URL + path, {
      method: "POST",
      headers: { Authorization: token, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = (await response.json().catch(() => ({}))) as { message?: string };
    if (response.status === 401) await this.storage.delete("clickpesa.token");
    if (!response.ok) {
      console.warn("clickpesa", path, response.status, data.message);
      return { ok: false, message: data.message ?? "The payment provider declined the request." };
    }
    return { ok: true, data };
  }

  /** JWTs last one hour; reuse for 55 minutes because token calls count against the daily API cap. */
  private async token(): Promise<string | null> {
    const cached = await this.storage.get<{ token: string; expiresAt: number }>("clickpesa.token");
    if (cached && cached.expiresAt > Date.now()) return cached.token;
    const response = await fetch(`${BASE_URL}/generate-token`, {
      method: "POST",
      headers: { "client-id": this.env.CLICKPESA_CLIENT_ID ?? "", "api-key": this.env.CLICKPESA_API_KEY ?? "" },
    });
    if (!response.ok) {
      console.warn("clickpesa token failed", response.status);
      return null;
    }
    const data = (await response.json()) as { token?: string };
    if (!data.token) return null;
    const token = data.token.startsWith("Bearer ") ? data.token : `Bearer ${data.token}`;
    await this.storage.put("clickpesa.token", { token, expiresAt: Date.now() + 55 * 60_000 });
    return token;
  }
}

function canonicalize(value: unknown): unknown {
  if (value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map(canonicalize);
  const object = value as Record<string, unknown>;
  return Object.keys(object)
    .sort()
    .reduce<Record<string, unknown>>((acc, key) => {
      acc[key] = canonicalize(object[key]);
      return acc;
    }, {});
}

export async function checksum(key: string, payload: unknown): Promise<string> {
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey("raw", encoder.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(JSON.stringify(canonicalize(payload))));
  return Array.from(new Uint8Array(signature), (b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
