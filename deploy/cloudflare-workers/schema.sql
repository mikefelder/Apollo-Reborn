-- Apollo-Reborn notifications backend — D1 schema.
--
-- Designed for single-tenant push delivery. The Azure-backed apollo-backend
-- stores many more rows (subreddit watchers, trending posts, live activity
-- threads, IAP receipts). This MVP only persists what's needed for inbox
-- notifications.
--
-- All timestamps are stored as INTEGER unix seconds (UTC).

PRAGMA foreign_keys = ON;

-- One row per APNs device token.
-- `sandbox` reflects whether the token is from the sandbox APNs gateway
-- (true for ad-hoc / dev-signed sideloads, false for App Store / production).
CREATE TABLE IF NOT EXISTS devices (
    apns_token      TEXT PRIMARY KEY,
    sandbox         INTEGER NOT NULL DEFAULT 1,
    created_at      INTEGER NOT NULL,
    last_pinged_at  INTEGER
);

-- One row per Reddit account. The 4 reddit_* columns hold the per-account
-- OAuth client identity the sideloaded Apollo build injects at registration
-- time (each user runs their own Reddit OAuth app since Reddit revoked the
-- shared client_id in 2023).
--
-- access_token / refresh_token are rotated on every token refresh.
-- last_message_id is the `thing.fullname` of the most-recently-seen unread
-- inbox item; the cron handler diffs against this to find new messages.
CREATE TABLE IF NOT EXISTS accounts (
    reddit_id            TEXT PRIMARY KEY,    -- e.g. "1ia22" (without t2_ prefix)
    username             TEXT NOT NULL,
    access_token         TEXT NOT NULL,
    refresh_token        TEXT NOT NULL,
    token_expires_at     INTEGER NOT NULL,    -- unix seconds
    reddit_client_id     TEXT NOT NULL,
    reddit_client_secret TEXT NOT NULL,
    reddit_redirect_uri  TEXT NOT NULL,
    reddit_user_agent    TEXT NOT NULL,
    last_message_id      TEXT,                -- e.g. "t1_hwp66zg"
    last_checked_at      INTEGER,
    check_count          INTEGER NOT NULL DEFAULT 0,
    created_at           INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_accounts_username_lower ON accounts(LOWER(username));

-- M:N device <-> account association. The tweak can register the same Reddit
-- account against multiple devices (e.g. phone + iPad), and a device can be
-- signed into multiple Reddit accounts.
--
-- inbox_notifications / watcher_notifications / global_mute mirror the
-- per-account toggles the tweak PATCHes via /notifications. When global_mute
-- is true or inbox_notifications is false, the cron handler still records
-- seen messages but does not push.
CREATE TABLE IF NOT EXISTS device_accounts (
    apns_token            TEXT NOT NULL,
    reddit_id             TEXT NOT NULL,
    inbox_notifications   INTEGER NOT NULL DEFAULT 1,
    watcher_notifications INTEGER NOT NULL DEFAULT 1,
    global_mute           INTEGER NOT NULL DEFAULT 0,
    created_at            INTEGER NOT NULL,
    PRIMARY KEY (apns_token, reddit_id),
    FOREIGN KEY (apns_token) REFERENCES devices(apns_token) ON DELETE CASCADE,
    FOREIGN KEY (reddit_id)  REFERENCES accounts(reddit_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_device_accounts_reddit_id ON device_accounts(reddit_id);

-- Dedup table — every inbox `thing.fullname` we've sent for a given Reddit
-- account. Prevents duplicate pushes if Reddit briefly re-marks something
-- unread, or if last_message_id rollback fails for some reason.
--
-- Cron handler trims rows older than SEEN_TTL_SECONDS (default 30 days) to
-- keep D1 storage trivial.
CREATE TABLE IF NOT EXISTS seen_messages (
    reddit_id    TEXT NOT NULL,
    message_id   TEXT NOT NULL,                -- thing.fullname, e.g. "t1_xxxxx"
    seen_at      INTEGER NOT NULL,
    PRIMARY KEY (reddit_id, message_id),
    FOREIGN KEY (reddit_id) REFERENCES accounts(reddit_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_seen_messages_seen_at ON seen_messages(seen_at);
