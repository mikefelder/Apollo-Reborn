/**
 * HTTP router — Hono app implementing the apollo-backend wire surface that
 * Apollo-Reborn's ApolloNotificationBackend.m rewrites legacy traffic to.
 *
 * Endpoint contract (matches internal/api/api.go on Apollo-Reborn/apollo-backend):
 *
 *   Public:
 *     GET    /v1/health
 *     DELETE /v1/device/{apns}
 *     POST   /v1/device/{apns}/test
 *     DELETE /v1/device/{apns}/account/{redditID}
 *     PATCH  /v1/device/{apns}/account/{redditID}/notifications
 *     GET    /v1/device/{apns}/account/{redditID}/notifications
 *     watcher endpoints → 200/[] stubs (MVP doesn't implement subreddit watchers)
 *
 *   X-Registration-Token gated:
 *     POST   /v1/device
 *     POST   /v1/device/{apns}/account
 *     POST   /v1/device/{apns}/accounts
 *     POST   /v1/live_activities  → 200 stub (live activities not implemented)
 *
 *   Legacy 200/{} stubs the tweak occasionally hits:
 *     POST   /api/req_v2
 *     GET    /api/announcement
 *     POST   /v1/receipt[/{apns}]
 */

import { Hono } from "hono";
import { timingSafeEqualStrings } from "./auth.ts";
import * as db from "./db.ts";
import * as reddit from "./reddit.ts";
import { sendApnsPush } from "./apns.ts";
import { buildTestPayload } from "./notifications.ts";
import type { AccountNotificationsRequest, AccountRegistrationRequest, DeviceRegistrationRequest, Env } from "./types.ts";

export function buildRouter(): Hono<{ Bindings: Env }> {
    const app = new Hono<{ Bindings: Env }>();

    // ---- Health ----
    app.get("/v1/health", (c) => c.json({ status: "ok" }));

    // ---- Legacy 200 stubs (matches req_v2.go in the Go backend) ----
    app.post("/api/req_v2", (c) => c.json({}));
    app.get("/api/announcement", (c) => c.json({}));
    app.post("/v1/receipt", (c) => c.json({}));
    app.post("/v1/receipt/:apns", (c) => c.json({}));

    // ---- Live Activities — accept-and-drop ----
    // Returning 200 keeps the tweak quiet; we just don't drive ActivityKit.
    app.post("/v1/live_activities", registrationGate, (c) => c.json({}));

    // ---- Device registration ----
    app.post("/v1/device", registrationGate, async (c) => {
        const body = await safeJson<DeviceRegistrationRequest>(c.req.raw);
        if (!body || typeof body.apns_token !== "string" || body.apns_token.length === 0) {
            return c.json({ error: "missing apns_token" }, 422);
        }

        // APPLE_APNS_SANDBOX env var pins the gateway regardless of what the
        // client sent — must match the signing identity. The Go backend does
        // the same. Default to sandbox=true since this stack is aimed at
        // dev-signed sideloads.
        const sandbox = parseBool(c.env.APPLE_APNS_SANDBOX, true);
        await db.upsertDevice(c.env.DB, body.apns_token, sandbox);
        return c.json({}, 200);
    });

    app.delete("/v1/device/:apns", async (c) => {
        await db.deleteDevice(c.env.DB, c.req.param("apns"));
        return c.json({}, 200);
    });

    // ---- Test push ----
    app.post("/v1/device/:apns/test", async (c) => {
        const apns = c.req.param("apns");
        const device = await db.getDevice(c.env.DB, apns);
        if (!device) return c.json({ error: "device not registered" }, 422);

        const accounts = await db.listAccountsForDevice(c.env.DB, apns);
        const usernames = accounts.map((a) => a.username);

        const result = await sendApnsPush(c.env, {
            apnsToken: device.apns_token,
            sandbox: device.sandbox === 1,
            payload: buildTestPayload(usernames),
        });
        if (!result.ok) {
            return c.json({ error: `apns push failed: ${result.status} ${result.reason ?? ""}` }, 422);
        }
        return c.json({ ok: true });
    });

    // ---- Account registration (singular + bulk) ----
    app.post("/v1/device/:apns/account", registrationGate, async (c) => {
        // Hono guarantees the param is present when the route matched, but its
        // generic inference doesn't always propagate that through this overload;
        // assert string to keep the rest of the body strictly typed.
        const apns = c.req.param("apns") as string;
        const device = await db.getDevice(c.env.DB, apns);
        if (!device) return c.json({ error: "device not registered" }, 422);

        const body = await safeJson<AccountRegistrationRequest>(c.req.raw);
        if (!body) return c.json({ error: "invalid json" }, 422);

        const status = await registerOneAccount(c.env, device.apns_token, body);
        return c.json(status.body, status.code as 200 | 401 | 422 | 500);
    });

    app.post("/v1/device/:apns/accounts", registrationGate, async (c) => {
        const apns = c.req.param("apns") as string;
        const device = await db.getDevice(c.env.DB, apns);
        if (!device) return c.json({ error: "device not registered" }, 422);

        const body = await safeJson<AccountRegistrationRequest[]>(c.req.raw);
        if (!Array.isArray(body)) return c.json({ error: "expected json array" }, 422);

        // Disassociate accounts that aren't in the new list (matches Go backend).
        const existing = await db.listAccountsForDevice(c.env.DB, device.apns_token);
        const incomingUsernames = new Set(body.map((b) => (b.username ?? "").toLowerCase()));
        for (const acc of existing) {
            if (!incomingUsernames.has(acc.username.toLowerCase())) {
                await db.disassociate(c.env.DB, device.apns_token, acc.reddit_id);
            }
        }

        for (const req of body) {
            const status = await registerOneAccount(c.env, device.apns_token, req);
            if (status.code !== 200) {
                return c.json(status.body, status.code as 401 | 422 | 500);
            }
        }
        return c.json({}, 200);
    });

    app.delete("/v1/device/:apns/account/:redditID", async (c) => {
        await db.disassociate(c.env.DB, c.req.param("apns"), c.req.param("redditID"));
        return c.json({}, 200);
    });

    // ---- Notification settings ----
    app.patch("/v1/device/:apns/account/:redditID/notifications", async (c) => {
        const body = await safeJson<AccountNotificationsRequest>(c.req.raw);
        if (!body) return c.json({ error: "invalid json" }, 422);
        await db.setNotificationSettings(
            c.env.DB,
            c.req.param("apns"),
            c.req.param("redditID"),
            !!body.inbox_notifications,
            !!body.watcher_notifications,
            !!body.global_mute,
        );
        return c.json({}, 200);
    });

    app.get("/v1/device/:apns/account/:redditID/notifications", async (c) => {
        const settings = await db.getNotificationSettings(
            c.env.DB,
            c.req.param("apns"),
            c.req.param("redditID"),
        );
        const out: AccountNotificationsRequest = settings
            ? {
                inbox_notifications: settings.inbox,
                watcher_notifications: settings.watchers,
                global_mute: settings.mute,
            }
            : { inbox_notifications: true, watcher_notifications: true, global_mute: false };
        return c.json(out);
    });

    // ---- Watcher endpoints — 200 stubs ----
    // Subreddit watchers require continuous /r/<sub>/new polling which is
    // a much bigger commitment than inbox checks. Returning 200/[] keeps the
    // tweak from erroring without misleading the user into thinking it works.
    app.post("/v1/device/:apns/account/:redditID/watcher", (c) => c.json({}, 200));
    app.delete("/v1/device/:apns/account/:redditID/watcher/:watcherID", (c) =>
        c.json({}, 200),
    );
    app.patch("/v1/device/:apns/account/:redditID/watcher/:watcherID", (c) =>
        c.json({}, 200),
    );
    app.get("/v1/device/:apns/account/:redditID/watchers", (c) => c.json([]));

    // ---- 404 / global error ----
    app.notFound((c) => c.json({ error: "not found", path: c.req.path }, 404));
    app.onError((err, c) => {
        console.error("[router] unhandled:", err);
        return c.json({ error: "internal error" }, 500);
    });

    return app;
}

// ===== Helpers =====

import type { Context, Next } from "hono";

async function registrationGate(c: Context<{ Bindings: Env }>, next: Next): Promise<Response | void> {
    const expected = c.env.REGISTRATION_SECRET;
    if (!expected || expected.length === 0) {
        // Misconfiguration — fail closed so a deploy without the secret
        // doesn't accidentally allow unauthenticated writes.
        return c.json({ error: "server missing REGISTRATION_SECRET" }, 503);
    }
    const supplied = c.req.header("x-registration-token") ?? "";
    if (!timingSafeEqualStrings(supplied, expected)) {
        return c.json({ error: "invalid registration token" }, 401);
    }
    await next();
}

async function safeJson<T>(req: Request): Promise<T | null> {
    try {
        return (await req.json()) as T;
    } catch {
        return null;
    }
}

function parseBool(raw: string | undefined, fallback: boolean): boolean {
    if (raw === undefined) return fallback;
    const v = raw.trim().toLowerCase();
    if (v === "1" || v === "true" || v === "yes") return true;
    if (v === "0" || v === "false" || v === "no") return false;
    return fallback;
}

interface RegisterResult {
    code: number;
    body: Record<string, unknown>;
}

/**
 * The Go backend's registerAccount path, ported to TS:
 *   1. Normalize camelCase -> snake_case for accessToken/refreshToken
 *   2. Refresh the OAuth token (validates the refresh_token is live)
 *   3. GET /api/v1/me to fetch the canonical username + id
 *   4. Verify the username matches what the client sent
 *   5. Upsert account + associate with device
 */
async function registerOneAccount(
    env: Env,
    apnsToken: string,
    req: AccountRegistrationRequest,
): Promise<RegisterResult> {
    const username = (req.username ?? "").trim();
    if (!username) return { code: 422, body: { error: "missing username" } };

    const accessToken = req.access_token ?? req.accessToken ?? "";
    const refreshToken = req.refresh_token ?? req.refreshToken ?? "";
    const clientId = req.reddit_client_id ?? "";
    const clientSecret = req.reddit_client_secret ?? "";
    const redirectUri = req.reddit_redirect_uri ?? "";
    const userAgent = req.reddit_user_agent ?? env.REDDIT_USER_AGENT;

    if (!accessToken || !refreshToken || !clientId || !clientSecret) {
        return {
            code: 422,
            body: { error: "missing required reddit credentials in body" },
        };
    }

    // Use a temporary account-shaped object to drive refresh + me. We don't
    // persist anything until the username verification succeeds.
    const probe = {
        reddit_id: "",
        username,
        access_token: accessToken,
        refresh_token: refreshToken,
        token_expires_at: 0,
        reddit_client_id: clientId,
        reddit_client_secret: clientSecret,
        reddit_redirect_uri: redirectUri,
        reddit_user_agent: userAgent,
        last_message_id: null,
        last_checked_at: null,
        check_count: 0,
        created_at: 0,
    };

    let fresh: { access_token: string; refresh_token: string; expires_at: number };
    try {
        fresh = await reddit.refreshAccessToken(probe);
    } catch (err) {
        return {
            code: 422,
            body: { error: `failed to refresh tokens: ${(err as Error).message}` },
        };
    }

    let me: { id: string; name: string };
    try {
        me = await reddit.fetchMe(fresh.access_token, userAgent);
    } catch (err) {
        return {
            code: 500,
            body: { error: `failed to fetch user info: ${(err as Error).message}` },
        };
    }

    if (me.name.toLowerCase() !== username.toLowerCase()) {
        return {
            code: 401,
            body: { error: `wrong user: expected ${me.name}, got ${username}` },
        };
    }

    await db.upsertAccount(env.DB, {
        reddit_id: me.id,
        username: me.name,
        access_token: fresh.access_token,
        refresh_token: fresh.refresh_token,
        token_expires_at: fresh.expires_at,
        reddit_client_id: clientId,
        reddit_client_secret: clientSecret,
        reddit_redirect_uri: redirectUri,
        reddit_user_agent: userAgent,
    });
    await db.associate(env.DB, apnsToken, me.id);

    return { code: 200, body: {} };
}
