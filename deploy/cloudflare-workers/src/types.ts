/**
 * Shared types for the Apollo-Reborn notifications worker.
 *
 * Env reflects every binding declared in wrangler.toml plus the secrets
 * registered via `wrangler secret put`. Keep this in lockstep with both.
 */

import type { D1Database } from "@cloudflare/workers-types";

export interface Env {
    // --- D1 binding (wrangler.toml [[d1_databases]]) ---
    DB: D1Database;

    // --- [vars] (non-secret runtime config) ---
    APPLE_TEAM_ID: string;
    APPLE_APNS_TOPIC: string;
    APPLE_APNS_SANDBOX: string; // "true" | "false"
    REDDIT_USER_AGENT: string;
    POLL_MAX_ACCOUNTS: string; // numeric string
    SEEN_TTL_SECONDS: string;  // numeric string

    // --- secrets (wrangler secret put) ---
    APPLE_KEY_PEM: string;        // raw .p8 contents incl. PEM header/footer
    APPLE_KEY_ID: string;         // 10-char key identifier from Apple developer portal
    REGISTRATION_SECRET: string;  // bearer token the tweak sends as X-Registration-Token
}

// ===== Wire types — what the tweak POSTs =====

/** POST /v1/device body. */
export interface DeviceRegistrationRequest {
    apns_token: string;
    sandbox?: boolean;
}

/**
 * POST /v1/device/{apns}/account body (and array elements of /accounts).
 *
 * The tweak's ApolloNotificationBackend.m augments the body to add the four
 * reddit_* fields from the user's saved settings. The original Apollo client
 * also emits accessToken/refreshToken in camelCase, so we accept both spellings
 * and snake_case wins when both appear (mirrors the Go backend's UnmarshalJSON).
 */
export interface AccountRegistrationRequest {
    username: string;
    access_token?: string;
    refresh_token?: string;
    accessToken?: string;
    refreshToken?: string;
    reddit_client_id?: string;
    reddit_client_secret?: string;
    reddit_redirect_uri?: string;
    reddit_user_agent?: string;
    development?: boolean;
}

/** PATCH /v1/device/{apns}/account/{redditID}/notifications body. */
export interface AccountNotificationsRequest {
    inbox_notifications: boolean;
    watcher_notifications: boolean;
    global_mute: boolean;
}

// ===== DB row types =====

export interface DeviceRow {
    apns_token: string;
    sandbox: number;        // 0/1 (D1 has no native bool)
    created_at: number;
    last_pinged_at: number | null;
}

export interface AccountRow {
    reddit_id: string;
    username: string;
    access_token: string;
    refresh_token: string;
    token_expires_at: number;
    reddit_client_id: string;
    reddit_client_secret: string;
    reddit_redirect_uri: string;
    reddit_user_agent: string;
    last_message_id: string | null;
    last_checked_at: number | null;
    check_count: number;
    created_at: number;
}

export interface DeviceAccountRow {
    apns_token: string;
    reddit_id: string;
    inbox_notifications: number;
    watcher_notifications: number;
    global_mute: number;
    created_at: number;
}

// ===== Reddit API response slices =====

export interface RedditTokenResponse {
    access_token: string;
    refresh_token?: string;
    expires_in: number; // seconds
    scope?: string;
    token_type?: string;
}

export interface RedditMeResponse {
    id: string;          // e.g. "1ia22"
    name: string;        // username (case-preserving)
}

/** One element of /message/unread.json -> data.children[]. */
export interface RedditThing {
    kind: string;        // "t1" (comment) | "t4" (PM)
    data: {
        id: string;
        name: string;             // fullname, e.g. "t1_hwp66zg"
        author?: string;
        body?: string;
        subject?: string;
        subreddit?: string;
        link_title?: string;
        link_id?: string;
        parent_id?: string;
        context?: string;
        was_comment?: boolean;
        type?: string;            // "comment_reply" | "post_reply" | "username_mention"
        dest?: string;            // username being messaged
        created_utc?: number;
    };
}

export interface RedditListing<T> {
    kind: string; // "Listing"
    data: {
        children: T[];
        after: string | null;
        before: string | null;
    };
}
