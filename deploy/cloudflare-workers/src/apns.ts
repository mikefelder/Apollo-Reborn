/**
 * APNs HTTP/2 client for Cloudflare Workers.
 *
 * The Workers runtime exposes the WebCrypto API (`crypto.subtle`) and Apple's
 * APNs auth needs an ES256 JWT signed with a P-256 EC private key. Web Crypto
 * outputs ECDSA signatures in IEEE P1363 raw r||s format — which IS exactly
 * what JWT ES256 wants. No DER unwrapping needed.
 *
 * APNs JWTs are valid for up to 60 minutes; Apple actually rate-limits how
 * often you can generate new ones (TooManyProviderTokenUpdates), so we cache
 * the JWT in module scope for ~55 minutes between regenerations.
 *
 * Outbound fetch() from a Worker negotiates HTTP/2 transparently, so we can
 * just POST to api.sandbox.push.apple.com / api.push.apple.com directly.
 */

import type { Env } from "./types.ts";

interface CachedJwt {
    token: string;
    expiresAt: number; // unix seconds
    keyId: string;
    teamId: string;
}

// Module-scope cache. Each Worker isolate keeps its own copy; that's fine —
// regenerating the JWT per isolate stays well below APNs rate limits at single-
// user volume.
let cachedJwt: CachedJwt | null = null;
let cachedSigningKey: CryptoKey | null = null;
let cachedSigningKeyPem: string | null = null;

const JWT_LIFETIME_SECONDS = 55 * 60; // refresh before APNs's 60-minute ceiling

/**
 * Imports a PEM-encoded PKCS#8 EC private key (Apple's .p8 download format)
 * into a non-extractable CryptoKey suitable for ECDSA-SHA256 signing.
 */
async function importApnsKey(pem: string): Promise<CryptoKey> {
    if (cachedSigningKey && cachedSigningKeyPem === pem) {
        return cachedSigningKey;
    }
    const trimmed = pem
        .replace(/-----BEGIN PRIVATE KEY-----/g, "")
        .replace(/-----END PRIVATE KEY-----/g, "")
        .replace(/\s+/g, "");
    if (trimmed.length === 0) {
        throw new Error("APPLE_KEY_PEM is empty or malformed");
    }
    const der = base64ToBytes(trimmed);
    const key = await crypto.subtle.importKey(
        "pkcs8",
        der,
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"],
    );
    cachedSigningKey = key;
    cachedSigningKeyPem = pem;
    return key;
}

/**
 * Returns a cached or freshly-signed APNs provider JWT for this team+key pair.
 * Invalidated when the key ID, team ID, or PEM contents change.
 */
async function getApnsJwt(env: Env): Promise<string> {
    const nowSec = Math.floor(Date.now() / 1000);
    if (
        cachedJwt &&
        cachedJwt.expiresAt > nowSec &&
        cachedJwt.keyId === env.APPLE_KEY_ID &&
        cachedJwt.teamId === env.APPLE_TEAM_ID
    ) {
        return cachedJwt.token;
    }

    const key = await importApnsKey(env.APPLE_KEY_PEM);
    const header = { alg: "ES256", kid: env.APPLE_KEY_ID, typ: "JWT" };
    const claims = { iss: env.APPLE_TEAM_ID, iat: nowSec };
    const signingInput =
        base64UrlEncodeString(JSON.stringify(header)) +
        "." +
        base64UrlEncodeString(JSON.stringify(claims));
    const sigBuf = await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        key,
        new TextEncoder().encode(signingInput),
    );
    const token = signingInput + "." + base64UrlEncodeBytes(new Uint8Array(sigBuf));
    cachedJwt = {
        token,
        expiresAt: nowSec + JWT_LIFETIME_SECONDS,
        keyId: env.APPLE_KEY_ID,
        teamId: env.APPLE_TEAM_ID,
    };
    return token;
}

export interface ApnsPayload {
    aps: {
        alert?: {
            title?: string;
            subtitle?: string;
            body?: string;
            "title-loc-key"?: string;
            "summary-arg"?: string;
        };
        sound?: string | { name: string; critical?: 0 | 1; volume?: number };
        category?: string;
        "mutable-content"?: 1;
        "thread-id"?: string;
        badge?: number;
    };
    // Anything else is delivered as user-info — Apollo's UN action handlers
    // pull authoring metadata (post_id, comment_id, etc.) from here.
    [k: string]: unknown;
}

export interface SendOptions {
    apnsToken: string;
    sandbox: boolean;
    payload: ApnsPayload;
    collapseId?: string;
    priority?: 5 | 10;
    pushType?: "alert" | "background";
    expiration?: number;
}

export interface SendResult {
    ok: boolean;
    status: number;
    apnsId?: string;
    /** Apple's `reason` body field on failure, e.g. "BadDeviceToken". */
    reason?: string;
}

/**
 * Sends a single push via APNs HTTP/2. Returns ok=false on non-2xx so the
 * caller can decide whether to delete the device (BadDeviceToken / Unregistered)
 * vs retry next tick.
 */
export async function sendApnsPush(env: Env, opts: SendOptions): Promise<SendResult> {
    const host = opts.sandbox
        ? "https://api.sandbox.push.apple.com"
        : "https://api.push.apple.com";
    const url = `${host}/3/device/${opts.apnsToken}`;

    const jwt = await getApnsJwt(env);
    const headers: Record<string, string> = {
        authorization: `bearer ${jwt}`,
        "apns-topic": env.APPLE_APNS_TOPIC,
        "apns-push-type": opts.pushType ?? "alert",
        "apns-priority": String(opts.priority ?? 10),
        "apns-expiration": String(opts.expiration ?? 0),
        "content-type": "application/json",
    };
    if (opts.collapseId) headers["apns-collapse-id"] = opts.collapseId;

    const res = await fetch(url, {
        method: "POST",
        headers,
        body: JSON.stringify(opts.payload),
    });

    if (res.ok) {
        return { ok: true, status: res.status, apnsId: res.headers.get("apns-id") ?? undefined };
    }
    // Apple returns JSON like {"reason":"BadDeviceToken"} on errors.
    let reason: string | undefined;
    try {
        const body = (await res.json()) as { reason?: string };
        reason = body.reason;
    } catch {
        // Some failures (e.g. 5xx HTML pages) won't be JSON.
    }
    return { ok: false, status: res.status, reason };
}

// ===== base64 helpers =====
//
// Workers exposes atob/btoa. We need URL-safe base64 (no padding) for JWTs
// and standard base64 for PKCS8 decoding.

function base64UrlEncodeString(s: string): string {
    return base64UrlEncodeBytes(new TextEncoder().encode(s));
}

function base64UrlEncodeBytes(bytes: Uint8Array): string {
    // btoa expects a binary string. Workers caps argument count for spread,
    // but APNs JWT payloads are tens of bytes so this is fine.
    let bin = "";
    for (let i = 0; i < bytes.length; i++) {
        bin += String.fromCharCode(bytes[i] as number);
    }
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function base64ToBytes(b64: string): Uint8Array {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) {
        out[i] = bin.charCodeAt(i);
    }
    return out;
}
