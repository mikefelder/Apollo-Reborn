/**
 * Reddit OAuth + Inbox API client.
 *
 * Each account owns its own OAuth client_id/secret (the apollo-backend fork
 * shifted off the shared Apollo creds Reddit revoked in 2023). All requests
 * here read those per-account credentials from the AccountRow.
 *
 * User-Agent rule: Reddit's API explicitly rejects requests without
 * "(by /u/<name>)" in the User-Agent. The tweak's saved UA always includes it
 * — we just pass it through unchanged.
 */

import type { AccountRow, RedditListing, RedditMeResponse, RedditThing, RedditTokenResponse } from "./types.ts";

const TOKEN_URL = "https://www.reddit.com/api/v1/access_token";
const OAUTH_BASE = "https://oauth.reddit.com";

/**
 * Posts to /api/v1/access_token with Basic auth using the account's client
 * credentials. Used both for refresh and (in the future) initial code grants.
 */
async function postToken(
    account: Pick<AccountRow, "reddit_client_id" | "reddit_client_secret" | "reddit_user_agent">,
    form: Record<string, string>,
): Promise<RedditTokenResponse> {
    const body = new URLSearchParams(form).toString();
    const basic = btoa(`${account.reddit_client_id}:${account.reddit_client_secret}`);
    const res = await fetch(TOKEN_URL, {
        method: "POST",
        headers: {
            authorization: `Basic ${basic}`,
            "content-type": "application/x-www-form-urlencoded",
            "user-agent": account.reddit_user_agent,
            accept: "application/json",
        },
        body,
    });
    if (!res.ok) {
        const text = await safeText(res);
        throw new Error(`reddit token request failed: ${res.status} ${text}`);
    }
    const json = (await res.json()) as RedditTokenResponse;
    if (!json.access_token) {
        throw new Error(`reddit token response missing access_token: ${JSON.stringify(json)}`);
    }
    return json;
}

/**
 * Refreshes an account's access token using its stored refresh_token.
 *
 * Reddit returns a new access_token (and sometimes rotates the refresh_token
 * too — caller should persist whichever is returned).
 */
export async function refreshAccessToken(account: AccountRow): Promise<{
    access_token: string;
    refresh_token: string;
    expires_at: number;
}> {
    const tokens = await postToken(account, {
        grant_type: "refresh_token",
        refresh_token: account.refresh_token,
    });
    return {
        access_token: tokens.access_token,
        // Reddit sometimes omits refresh_token from refresh responses — keep
        // the old one in that case.
        refresh_token: tokens.refresh_token ?? account.refresh_token,
        expires_at: Math.floor(Date.now() / 1000) + tokens.expires_in - 30,
    };
}

/**
 * GETs /api/v1/me. Used at registration to verify the Reddit account matches
 * the username the tweak sent (mitigates a misconfigured oauth app).
 */
export async function fetchMe(
    accessToken: string,
    userAgent: string,
): Promise<RedditMeResponse> {
    const res = await fetch(`${OAUTH_BASE}/api/v1/me`, {
        headers: {
            authorization: `bearer ${accessToken}`,
            "user-agent": userAgent,
            accept: "application/json",
        },
    });
    if (!res.ok) {
        const text = await safeText(res);
        throw new Error(`reddit me request failed: ${res.status} ${text}`);
    }
    const json = (await res.json()) as Partial<RedditMeResponse>;
    if (!json.id || !json.name) {
        throw new Error(`reddit me response missing id/name: ${JSON.stringify(json)}`);
    }
    return { id: json.id, name: json.name };
}

/**
 * GETs /message/unread.json with the account's access token.
 *
 * `before` is the fullname of the most-recent message already seen — Reddit
 * paginates "newer than X" via the `before` query param. On first fetch
 * (last_message_id is null) we pull the full unread page.
 */
export async function fetchUnreadMessages(
    accessToken: string,
    userAgent: string,
    before: string | null,
    limit = 25,
): Promise<RedditThing[]> {
    const url = new URL(`${OAUTH_BASE}/message/unread.json`);
    url.searchParams.set("limit", String(limit));
    url.searchParams.set("raw_json", "1");
    if (before) url.searchParams.set("before", before);

    const res = await fetch(url.toString(), {
        headers: {
            authorization: `bearer ${accessToken}`,
            "user-agent": userAgent,
            accept: "application/json",
        },
    });
    if (!res.ok) {
        const text = await safeText(res);
        throw new Error(`reddit unread request failed: ${res.status} ${text}`);
    }
    const json = (await res.json()) as Partial<RedditListing<RedditThing>>;
    const children = json?.data?.children;
    if (!Array.isArray(children)) return [];
    return children;
}

async function safeText(res: Response): Promise<string> {
    try {
        const t = await res.text();
        return t.length > 200 ? t.slice(0, 200) + "..." : t;
    } catch {
        return "<unreadable body>";
    }
}
