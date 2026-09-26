// functions/wallet-verifier.ts — proves a passenger owns a mobile money number before it can be linked.
//
// 1. Lookup: the network is read from the number's prefix, then confirmed with ClickPesa's sender
//    details (authoritative, survives number porting) which also return the registered account name.
// 2. OTP: a 6-digit code is sent by SMS (Beem Africa). Only a hash is stored; 5 minutes, 5 attempts.
// 3. Verified numbers are recorded per device; the ledger refuses to charge any number not on that list.
//
// Without SMS keys the verifier runs in test mode and returns the code to the app so the flow works.

import type { ClickPesa } from "./clickpesa";
import { networkForPhone, normalisePhone } from "./payment-ledger";

export type VerifierEnv = {
  BEEM_API_KEY?: string;
  BEEM_SECRET_KEY?: string;
  BEEM_SENDER_ID?: string;
};

type Network = "mpesa" | "mixx" | "airtel" | "halopesa";

const NAMES: Record<Network, string> = { mpesa: "M-Pesa", mixx: "Mixx by Yas", airtel: "Airtel Money", halopesa: "HaloPesa" };
const CODE_TTL_MS = 5 * 60_000;
const MAX_ATTEMPTS = 5;
const RESEND_SPACING_MS = 30_000;
const MAX_SENDS_PER_HOUR = 6;
const LOOKUP_CACHE_MS = 24 * 60 * 60_000;

type VerificationRow = {
  id: string;
  device_id: string;
  phone: string;
  method: string;
  code_hash: string;
  attempts: number;
  created_at: number;
  verified_at: number | null;
};

export class WalletVerifier {
  constructor(
    private readonly storage: DurableObjectStorage,
    private readonly env: VerifierEnv,
    private readonly clickpesa: ClickPesa,
  ) {
    storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS verifications (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        phone TEXT NOT NULL,
        method TEXT NOT NULL,
        code_hash TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        verified_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS verified_wallets (
        device_id TEXT NOT NULL,
        phone TEXT NOT NULL,
        method TEXT NOT NULL,
        account_name TEXT,
        verified_at INTEGER NOT NULL,
        PRIMARY KEY (device_id, phone)
      );
      CREATE TABLE IF NOT EXISTS lookups (
        phone TEXT PRIMARY KEY,
        network TEXT,
        account_name TEXT,
        checked_at INTEGER NOT NULL
      );
    `);
  }

  get smsConfigured(): boolean {
    return Boolean(this.env.BEEM_API_KEY && this.env.BEEM_SECRET_KEY);
  }

  isVerified(deviceId: string, phone: string, method: string): boolean {
    return this.storage.sql
      .exec("SELECT 1 FROM verified_wallets WHERE device_id = ? AND phone = ? AND method = ?", deviceId, phone, method)
      .toArray().length > 0;
  }

  // MARK: Lookup

  async lookup(request: Request): Promise<Response> {
    const body = (await request.json().catch(() => null)) as { phone?: string } | null;
    const phone = normalisePhone(String(body?.phone ?? ""));
    if (!phone) return json({ error: "invalid_phone", message: "Enter a valid Tanzanian mobile number." }, 400);
    const result = await this.identify(phone);
    return json({ phone, ...result });
  }

  /** Prefix first; ClickPesa's sender details override it when available (ported numbers). */
  private async identify(phone: string): Promise<{ network: Network | null; accountName: string | null; confirmed: boolean }> {
    const prefixNetwork = networkForPhone(phone) as Network | null;
    const cached = this.storage.sql
      .exec<{ network: string | null; account_name: string | null; checked_at: number }>(
        "SELECT network, account_name, checked_at FROM lookups WHERE phone = ?", phone,
      ).toArray()[0];
    if (cached && Date.now() - cached.checked_at < LOOKUP_CACHE_MS) {
      return { network: (cached.network as Network | null) ?? prefixNetwork, accountName: cached.account_name, confirmed: cached.network !== null };
    }
    if (!this.clickpesa.isConfigured) return { network: prefixNetwork, accountName: null, confirmed: false };

    const sender = await this.clickpesa.senderDetails(phone);
    const network = providerToNetwork(sender?.accountProvider);
    const accountName = sender?.accountName?.trim() || null;
    this.storage.sql.exec(
      `INSERT INTO lookups (phone, network, account_name, checked_at) VALUES (?, ?, ?, ?)
       ON CONFLICT(phone) DO UPDATE SET network = excluded.network, account_name = excluded.account_name, checked_at = excluded.checked_at`,
      phone, network, accountName, Date.now(),
    );
    console.log("wallet lookup", { prefix: phone.slice(3, 5), network, confirmed: network !== null });
    return { network: network ?? prefixNetwork, accountName, confirmed: network !== null };
  }

  // MARK: OTP

  async send(request: Request): Promise<Response> {
    const deviceId = request.headers.get("X-Zuri-Device") ?? "";
    const body = (await request.json().catch(() => null)) as { phone?: string; method?: string } | null;
    const phone = normalisePhone(String(body?.phone ?? ""));
    const method = String(body?.method ?? "") as Network;
    if (deviceId.length < 8) return json({ error: "bad_request", message: "Missing device." }, 400);
    if (!phone) return json({ error: "invalid_phone", message: "Enter a valid Tanzanian mobile number." }, 400);
    if (!(method in NAMES)) return json({ error: "invalid_method", message: "Choose a mobile money wallet." }, 400);

    const identity = await this.identify(phone);
    if (identity.network && identity.network !== method) {
      return json({
        error: "network_mismatch",
        network: identity.network,
        message: `This number is on ${NAMES[identity.network]}, not ${NAMES[method]}.`,
      }, 400);
    }

    const now = Date.now();
    const recent = this.storage.sql
      .exec<{ created_at: number }>(
        "SELECT created_at FROM verifications WHERE device_id = ? AND created_at > ? ORDER BY created_at DESC", deviceId, now - 3_600_000,
      ).toArray();
    if (recent.length >= MAX_SENDS_PER_HOUR) {
      return json({ error: "too_many_codes", message: "Too many codes requested. Try again in an hour." }, 429);
    }
    const last = recent[0];
    if (last && now - last.created_at < RESEND_SPACING_MS) {
      const wait = Math.ceil((RESEND_SPACING_MS - (now - last.created_at)) / 1000);
      return json({ error: "resend_too_soon", message: `Wait ${wait}s before requesting another code.` }, 429);
    }

    const code = makeCode();
    const id = crypto.randomUUID();
    this.storage.sql.exec(
      "INSERT INTO verifications (id, device_id, phone, method, code_hash, attempts, created_at, verified_at) VALUES (?, ?, ?, ?, ?, 0, ?, NULL)",
      id, deviceId, phone, method, await sha256(`${id}:${code}`), now,
    );

    const live = this.smsConfigured;
    if (live) {
      const sent = await this.sendSms(phone, `Zuri: ${code} ni namba yako ya kuthibitisha ${NAMES[method]}. Usimpe mtu yeyote. / Your Zuri code is ${code}. Never share it.`);
      if (!sent) return json({ error: "sms_failed", message: "We couldn't send the SMS. Try again." }, 502);
    }
    console.log("otp sent", { id, method, live, prefix: phone.slice(3, 5) });
    return json({
      verificationId: id,
      phone,
      network: identity.network,
      accountName: identity.accountName,
      expiresAt: new Date(now + CODE_TTL_MS).toISOString(),
      resendAfter: RESEND_SPACING_MS / 1000,
      live,
      testCode: live ? null : code,
    });
  }

  async verify(request: Request): Promise<Response> {
    const deviceId = request.headers.get("X-Zuri-Device") ?? "";
    const body = (await request.json().catch(() => null)) as { verificationId?: string; code?: string } | null;
    const id = String(body?.verificationId ?? "");
    const code = String(body?.code ?? "").replace(/\D/g, "");
    const row = this.storage.sql.exec<VerificationRow>("SELECT * FROM verifications WHERE id = ?", id).toArray()[0];
    if (!row || row.device_id !== deviceId) return json({ error: "not_found", message: "Request a new code." }, 404);
    if (row.verified_at) return json({ error: "used", message: "This code was already used. Request a new one." }, 409);
    if (Date.now() - row.created_at > CODE_TTL_MS) return json({ error: "expired", message: "The code expired. Request a new one." }, 410);
    if (row.attempts >= MAX_ATTEMPTS) return json({ error: "locked", message: "Too many wrong tries. Request a new code." }, 429);

    this.storage.sql.exec("UPDATE verifications SET attempts = attempts + 1 WHERE id = ?", id);
    const matches = timingSafeEqual(await sha256(`${id}:${code}`), row.code_hash);
    if (!matches) {
      const left = MAX_ATTEMPTS - row.attempts - 1;
      return json({ error: "wrong_code", attemptsLeft: left, message: left > 0 ? `Wrong code. ${left} ${left === 1 ? "try" : "tries"} left.` : "Too many wrong tries. Request a new code." }, 400);
    }

    const now = Date.now();
    const accountName = this.storage.sql
      .exec<{ account_name: string | null }>("SELECT account_name FROM lookups WHERE phone = ?", row.phone).toArray()[0]?.account_name ?? null;
    this.storage.sql.exec("UPDATE verifications SET verified_at = ? WHERE id = ?", now, id);
    this.storage.sql.exec(
      `INSERT INTO verified_wallets (device_id, phone, method, account_name, verified_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(device_id, phone) DO UPDATE SET method = excluded.method, account_name = excluded.account_name, verified_at = excluded.verified_at`,
      deviceId, row.phone, row.method, accountName, now,
    );
    console.log("otp verified", { id, method: row.method });
    return json({ verified: true, phone: row.phone, method: row.method, accountName });
  }

  private async sendSms(phone: string, message: string): Promise<boolean> {
    try {
      const response = await fetch("https://apisms.beem.africa/v1/send", {
        method: "POST",
        headers: {
          Authorization: "Basic " + btoa(`${this.env.BEEM_API_KEY}:${this.env.BEEM_SECRET_KEY}`),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          source_addr: this.env.BEEM_SENDER_ID || "INFO",
          schedule_time: "",
          encoding: 0,
          message,
          recipients: [{ recipient_id: 1, dest_addr: phone }],
        }),
      });
      const data = (await response.json().catch(() => ({}))) as { successful?: boolean; code?: number; message?: string };
      if (!response.ok || data.successful === false) {
        console.warn("sms failed", response.status, data.code, data.message);
        return false;
      }
      return true;
    } catch (error) {
      console.warn("sms error", error instanceof Error ? error.message : String(error));
      return false;
    }
  }
}

/** ClickPesa provider labels (M-PESA, TIGO-PESA, MIXX BY YAS, AIRTEL-MONEY, HALOPESA) to Zuri rails. */
export function providerToNetwork(provider: string | undefined | null): Network | null {
  const text = (provider ?? "").toUpperCase().replace(/[^A-Z]/g, "");
  if (!text) return null;
  if (text.includes("HALO")) return "halopesa";
  if (text.includes("TIGO") || text.includes("MIXX") || text.includes("YAS")) return "mixx";
  if (text.includes("AIRTEL")) return "airtel";
  if (text.includes("MPESA") || text.includes("VODA")) return "mpesa";
  return null;
}

function makeCode(): string {
  const value = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return value.toString().padStart(6, "0");
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
