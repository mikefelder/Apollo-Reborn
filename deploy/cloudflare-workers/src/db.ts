/**
 * D1 query helpers.
 *
 * D1 uses prepared statements with positional ? placeholders — never
 * interpolate user data into the SQL string. Every helper here parameterizes
 * inputs.
 */

import type { D1Database } from "@cloudflare/workers-types";
import type { AccountRow, DeviceAccountRow, DeviceRow } from "./types.ts";

export const now = (): number => Math.floor(Date.now() / 1000);

// ===== devices =====

export async function upsertDevice(
    db: D1Database,
    apnsToken: string,
    sandbox: boolean,
): Promise<void> {
    await db
        .prepare(
            `INSERT INTO devices (apns_token, sandbox, created_at, last_pinged_at)
             VALUES (?, ?, ?, ?)
             ON CONFLICT(apns_token) DO UPDATE
             SET sandbox = excluded.sandbox,
                 last_pinged_at = excluded.last_pinged_at`,
        )
        .bind(apnsToken, sandbox ? 1 : 0, now(), now())
        .run();
}

export async function getDevice(
    db: D1Database,
    apnsToken: string,
): Promise<DeviceRow | null> {
    const row = await db
        .prepare(`SELECT * FROM devices WHERE apns_token = ?`)
        .bind(apnsToken)
        .first<DeviceRow>();
    return row ?? null;
}

export async function deleteDevice(
    db: D1Database,
    apnsToken: string,
): Promise<void> {
    // ON DELETE CASCADE handles device_accounts. seen_messages is per-account
    // (not per-device) and is preserved so re-registering the same account on
    // a fresh device doesn't re-deliver every old inbox item.
    await db
        .prepare(`DELETE FROM devices WHERE apns_token = ?`)
        .bind(apnsToken)
        .run();
}

// ===== accounts =====

export async function upsertAccount(
    db: D1Database,
    a: Omit<AccountRow, "created_at" | "last_message_id" | "last_checked_at" | "check_count"> &
        Partial<Pick<AccountRow, "last_message_id" | "last_checked_at" | "check_count">>,
): Promise<void> {
    await db
        .prepare(
            `INSERT INTO accounts (
                reddit_id, username, access_token, refresh_token, token_expires_at,
                reddit_client_id, reddit_client_secret, reddit_redirect_uri, reddit_user_agent,
                last_message_id, last_checked_at, check_count, created_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(reddit_id) DO UPDATE
             SET username = excluded.username,
                 access_token = excluded.access_token,
                 refresh_token = excluded.refresh_token,
                 token_expires_at = excluded.token_expires_at,
                 reddit_client_id = excluded.reddit_client_id,
                 reddit_client_secret = excluded.reddit_client_secret,
                 reddit_redirect_uri = excluded.reddit_redirect_uri,
                 reddit_user_agent = excluded.reddit_user_agent`,
        )
        .bind(
            a.reddit_id,
            a.username,
            a.access_token,
            a.refresh_token,
            a.token_expires_at,
            a.reddit_client_id,
            a.reddit_client_secret,
            a.reddit_redirect_uri,
            a.reddit_user_agent,
            a.last_message_id ?? null,
            a.last_checked_at ?? null,
            a.check_count ?? 0,
            now(),
        )
        .run();
}

export async function updateAccountTokens(
    db: D1Database,
    redditId: string,
    accessToken: string,
    refreshToken: string,
    expiresAt: number,
): Promise<void> {
    await db
        .prepare(
            `UPDATE accounts
             SET access_token = ?, refresh_token = ?, token_expires_at = ?
             WHERE reddit_id = ?`,
        )
        .bind(accessToken, refreshToken, expiresAt, redditId)
        .run();
}

export async function setAccountLastMessage(
    db: D1Database,
    redditId: string,
    lastMessageId: string | null,
): Promise<void> {
    await db
        .prepare(
            `UPDATE accounts
             SET last_message_id = ?, last_checked_at = ?, check_count = check_count + 1
             WHERE reddit_id = ?`,
        )
        .bind(lastMessageId, now(), redditId)
        .run();
}

export async function getAccount(
    db: D1Database,
    redditId: string,
): Promise<AccountRow | null> {
    const row = await db
        .prepare(`SELECT * FROM accounts WHERE reddit_id = ?`)
        .bind(redditId)
        .first<AccountRow>();
    return row ?? null;
}

export async function getAccountByUsername(
    db: D1Database,
    username: string,
): Promise<AccountRow | null> {
    const row = await db
        .prepare(`SELECT * FROM accounts WHERE LOWER(username) = LOWER(?)`)
        .bind(username)
        .first<AccountRow>();
    return row ?? null;
}

export async function listAllAccountsForPolling(
    db: D1Database,
    limit: number,
): Promise<AccountRow[]> {
    // Polling order: least-recently-checked first so a single account never
    // starves others when we hit POLL_MAX_ACCOUNTS per tick.
    const { results } = await db
        .prepare(
            `SELECT * FROM accounts
             ORDER BY COALESCE(last_checked_at, 0) ASC
             LIMIT ?`,
        )
        .bind(limit)
        .all<AccountRow>();
    return results ?? [];
}

// ===== device_accounts =====

export async function associate(
    db: D1Database,
    apnsToken: string,
    redditId: string,
): Promise<void> {
    await db
        .prepare(
            `INSERT INTO device_accounts (apns_token, reddit_id, created_at)
             VALUES (?, ?, ?)
             ON CONFLICT(apns_token, reddit_id) DO NOTHING`,
        )
        .bind(apnsToken, redditId, now())
        .run();
}

export async function disassociate(
    db: D1Database,
    apnsToken: string,
    redditId: string,
): Promise<void> {
    await db
        .prepare(
            `DELETE FROM device_accounts WHERE apns_token = ? AND reddit_id = ?`,
        )
        .bind(apnsToken, redditId)
        .run();
}

export async function listDeviceAccountsForReddit(
    db: D1Database,
    redditId: string,
): Promise<DeviceAccountRow[]> {
    const { results } = await db
        .prepare(`SELECT * FROM device_accounts WHERE reddit_id = ?`)
        .bind(redditId)
        .all<DeviceAccountRow>();
    return results ?? [];
}

export async function listAccountsForDevice(
    db: D1Database,
    apnsToken: string,
): Promise<AccountRow[]> {
    const { results } = await db
        .prepare(
            `SELECT a.* FROM accounts a
             JOIN device_accounts da ON da.reddit_id = a.reddit_id
             WHERE da.apns_token = ?`,
        )
        .bind(apnsToken)
        .all<AccountRow>();
    return results ?? [];
}

export async function getNotificationSettings(
    db: D1Database,
    apnsToken: string,
    redditId: string,
): Promise<{ inbox: boolean; watchers: boolean; mute: boolean } | null> {
    const row = await db
        .prepare(
            `SELECT inbox_notifications, watcher_notifications, global_mute
             FROM device_accounts
             WHERE apns_token = ? AND reddit_id = ?`,
        )
        .bind(apnsToken, redditId)
        .first<Pick<DeviceAccountRow, "inbox_notifications" | "watcher_notifications" | "global_mute">>();
    if (!row) return null;
    return {
        inbox: row.inbox_notifications === 1,
        watchers: row.watcher_notifications === 1,
        mute: row.global_mute === 1,
    };
}

export async function setNotificationSettings(
    db: D1Database,
    apnsToken: string,
    redditId: string,
    inbox: boolean,
    watchers: boolean,
    mute: boolean,
): Promise<void> {
    await db
        .prepare(
            `UPDATE device_accounts
             SET inbox_notifications = ?, watcher_notifications = ?, global_mute = ?
             WHERE apns_token = ? AND reddit_id = ?`,
        )
        .bind(inbox ? 1 : 0, watchers ? 1 : 0, mute ? 1 : 0, apnsToken, redditId)
        .run();
}

// ===== seen_messages =====

export async function filterNewMessages(
    db: D1Database,
    redditId: string,
    fullnames: string[],
): Promise<string[]> {
    if (fullnames.length === 0) return [];
    // D1 doesn't expand JS arrays into ? placeholders; build placeholders
    // explicitly. Inputs are Reddit-generated fullnames (alphanumerics + _),
    // not user-controlled strings, but we still bind them as parameters.
    const placeholders = fullnames.map(() => "?").join(", ");
    const { results } = await db
        .prepare(
            `SELECT message_id FROM seen_messages
             WHERE reddit_id = ? AND message_id IN (${placeholders})`,
        )
        .bind(redditId, ...fullnames)
        .all<{ message_id: string }>();
    const seen = new Set((results ?? []).map((r) => r.message_id));
    return fullnames.filter((id) => !seen.has(id));
}

export async function markSeen(
    db: D1Database,
    redditId: string,
    fullnames: string[],
): Promise<void> {
    if (fullnames.length === 0) return;
    // Batch insert in a single statement using a VALUES clause. D1 batches
    // multiple prepares but a single multi-row INSERT is one less round trip.
    const ts = now();
    const placeholders = fullnames.map(() => "(?, ?, ?)").join(", ");
    const bindings: (string | number)[] = [];
    for (const id of fullnames) {
        bindings.push(redditId, id, ts);
    }
    await db
        .prepare(
            `INSERT OR IGNORE INTO seen_messages (reddit_id, message_id, seen_at)
             VALUES ${placeholders}`,
        )
        .bind(...bindings)
        .run();
}

export async function trimSeenOlderThan(
    db: D1Database,
    cutoff: number,
): Promise<void> {
    await db
        .prepare(`DELETE FROM seen_messages WHERE seen_at < ?`)
        .bind(cutoff)
        .run();
}
