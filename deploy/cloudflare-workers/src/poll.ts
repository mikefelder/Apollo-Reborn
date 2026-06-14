/**
 * Cron handler — polls Reddit for unread inbox messages and pushes new ones
 * to every device associated with each account.
 *
 * Runs every minute (configured in wrangler.toml [triggers]). Each invocation
 * gets up to 30s of wallclock; we process up to POLL_MAX_ACCOUNTS least-
 * recently-checked accounts per tick.
 */

import * as db from "./db.ts";
import * as reddit from "./reddit.ts";
import { sendApnsPush } from "./apns.ts";
import { buildInboxPayload } from "./notifications.ts";
import type { AccountRow, Env } from "./types.ts";

export interface PollSummary {
    accountsChecked: number;
    accountsFailed: number;
    pushesSent: number;
    pushesFailed: number;
    trimmedSeenRows: boolean;
}

/**
 * Top-level cron entrypoint. Iterates accounts sequentially — for single-user
 * deployments concurrency offers no real win and serial keeps us well under
 * Cloudflare's subrequest limit.
 */
export async function runPoll(env: Env): Promise<PollSummary> {
    const maxAccounts = parsePositiveInt(env.POLL_MAX_ACCOUNTS, 10);
    const accounts = await db.listAllAccountsForPolling(env.DB, maxAccounts);

    let pushesSent = 0;
    let pushesFailed = 0;
    let accountsFailed = 0;

    for (const account of accounts) {
        try {
            const result = await pollAccount(env, account);
            pushesSent += result.pushesSent;
            pushesFailed += result.pushesFailed;
        } catch (err) {
            accountsFailed++;
            console.error(
                `[poll] account=${account.username} (${account.reddit_id}) failed:`,
                err instanceof Error ? err.message : String(err),
            );
        }
    }

    // Trim seen_messages roughly once per hour to keep the dedup table small.
    // Cheap operation but no point hammering it on every minute tick.
    let trimmedSeenRows = false;
    if (Math.floor(Date.now() / 1000 / 60) % 60 === 0) {
        const ttl = parsePositiveInt(env.SEEN_TTL_SECONDS, 30 * 86400);
        await db.trimSeenOlderThan(env.DB, Math.floor(Date.now() / 1000) - ttl);
        trimmedSeenRows = true;
    }

    return {
        accountsChecked: accounts.length,
        accountsFailed,
        pushesSent,
        pushesFailed,
        trimmedSeenRows,
    };
}

interface AccountPollResult {
    pushesSent: number;
    pushesFailed: number;
}

async function pollAccount(env: Env, account: AccountRow): Promise<AccountPollResult> {
    let working = account;

    // Refresh token if it's within 60 seconds of expiry.
    const nowSec = Math.floor(Date.now() / 1000);
    if (working.token_expires_at - nowSec < 60) {
        const fresh = await reddit.refreshAccessToken(working);
        await db.updateAccountTokens(
            env.DB,
            working.reddit_id,
            fresh.access_token,
            fresh.refresh_token,
            fresh.expires_at,
        );
        working = {
            ...working,
            access_token: fresh.access_token,
            refresh_token: fresh.refresh_token,
            token_expires_at: fresh.expires_at,
        };
    }

    const items = await reddit.fetchUnreadMessages(
        working.access_token,
        working.reddit_user_agent,
        working.last_message_id,
    );

    if (items.length === 0) {
        // Still bump last_checked_at so the LRU polling order works.
        await db.setAccountLastMessage(env.DB, working.reddit_id, working.last_message_id);
        return { pushesSent: 0, pushesFailed: 0 };
    }

    // Reddit returns newest first. Dedup against seen_messages — covers the
    // edge case where last_message_id couldn't advance (e.g. push partially
    // failed mid-tick).
    const fullnames = items.map((i) => i.data.name);
    const newFullnames = new Set(await db.filterNewMessages(env.DB, working.reddit_id, fullnames));
    const newItems = items.filter((i) => newFullnames.has(i.data.name));

    if (newItems.length === 0) {
        await db.setAccountLastMessage(env.DB, working.reddit_id, items[0]?.data.name ?? working.last_message_id);
        return { pushesSent: 0, pushesFailed: 0 };
    }

    // Fan out — every device linked to this account that hasn't muted inbox.
    const associations = await db.listDeviceAccountsForReddit(env.DB, working.reddit_id);
    const targets = associations.filter(
        (da) => da.inbox_notifications === 1 && da.global_mute === 0,
    );

    let pushesSent = 0;
    let pushesFailed = 0;

    for (const assoc of targets) {
        const device = await db.getDevice(env.DB, assoc.apns_token);
        if (!device) continue;

        // Send oldest -> newest so the notification stream lands in order.
        for (const item of [...newItems].reverse()) {
            const payload = buildInboxPayload(item, working.reddit_id, working.username);
            if (!payload) continue;

            const result = await sendApnsPush(env, {
                apnsToken: device.apns_token,
                sandbox: device.sandbox === 1,
                payload,
            });
            if (result.ok) {
                pushesSent++;
            } else {
                pushesFailed++;
                console.warn(
                    `[apns] push failed status=${result.status} reason=${result.reason ?? ""} device=${device.apns_token.slice(0, 8)}...`,
                );
                // Apple says delete the device on these.
                if (
                    result.reason === "BadDeviceToken" ||
                    result.reason === "Unregistered" ||
                    result.reason === "DeviceTokenNotForTopic"
                ) {
                    await db.deleteDevice(env.DB, device.apns_token);
                    break;
                }
            }
        }
    }

    // Record everything we just processed as seen and advance the cursor to
    // the newest item Reddit returned, even if we filtered some out (so we
    // don't keep refetching them).
    await db.markSeen(env.DB, working.reddit_id, fullnames);
    await db.setAccountLastMessage(env.DB, working.reddit_id, items[0]?.data.name ?? working.last_message_id);

    return { pushesSent, pushesFailed };
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
    const n = Number.parseInt(raw ?? "", 10);
    return Number.isFinite(n) && n > 0 ? n : fallback;
}
