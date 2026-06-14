# Apollo-Reborn Notifications — Cloudflare Workers backend

A single-tenant push-notification backend for sideloaded Apollo-Reborn builds,
implemented as a Cloudflare Worker + D1 database + Cron Trigger. Runs entirely
on **Cloudflare's free tier**: ~$0/month at single-user volume.

This is an alternative to the [`deploy/azure-backend/`](../azure-backend) Terraform stack on the
`feature/notifications-azure` branch — same wire protocol, very different
operational footprint:

| | `feature/notifications-azure` | this branch |
| --- | --- | --- |
| Stack | Postgres Flex + 9 Container Apps replicas + Redis + jobs | 1 Worker + 1 D1 db |
| Realistic monthly cost (1 user) | ~$130 (or ~$50 right-sized) | $0 |
| Background work | scheduler container + 6 worker queues | `*/1 * * * *` cron trigger |
| Notification dedup | Postgres rows | D1 `seen_messages` table |
| Live Activities | yes | stubbed 200 (not supported) |
| Subreddit / trending / username watchers | yes | stubbed 200 (not supported) |
| What works | full apollo-backend feature set | inbox notifications only |

If you only need inbox notifications for one Reddit account, this is the
right path. If you need watchers, live activities, or a multi-tenant push
service, deploy the Azure stack instead.

## What runs on Cloudflare

| Component | Cloudflare resource | Free-tier ceiling |
| --- | --- | --- |
| HTTP + cron handler | Worker | 100k requests/day, 10ms CPU/req |
| Account + device storage | D1 database | 5M reads/day, 100k writes/day, 5 GB |
| Inbox polling schedule | Cron Trigger | unlimited |

A single user pushing through this backend uses well under 1% of every free
ceiling.

## Endpoints (matches the tweak's expectations)

`ApolloNotificationBackend.m` rewrites every request to the legacy
`apollopushserver.xyz` / `beta.apollonotifications.com` / `apolloreq.com`
hosts so they hit the configured backend URL. This worker implements the
subset of the apollo-backend wire surface the tweak actually calls:

| Method | Path | Auth | Implementation |
| --- | --- | --- | --- |
| GET | `/v1/health` | none | status probe |
| POST | `/v1/device` | `X-Registration-Token` | upsert APNs token |
| DELETE | `/v1/device/{apns}` | none | delete device + cascade |
| POST | `/v1/device/{apns}/test` | none | send test push to that device |
| POST | `/v1/device/{apns}/account` | `X-Registration-Token` | register Reddit account |
| POST | `/v1/device/{apns}/accounts` | `X-Registration-Token` | bulk register (with diff/disassociate) |
| DELETE | `/v1/device/{apns}/account/{redditID}` | none | unlink account from device |
| PATCH | `/v1/device/{apns}/account/{redditID}/notifications` | none | inbox/watcher/mute toggles |
| GET | `/v1/device/{apns}/account/{redditID}/notifications` | none | read toggles |
| POST | `/v1/live_activities` | `X-Registration-Token` | **200 stub** (not implemented) |
| watcher endpoints | * | none | **200/[] stubs** (not implemented) |
| POST | `/api/req_v2` | none | legacy 200 stub |
| GET | `/api/announcement` | none | legacy 200 stub |
| POST | `/v1/receipt[/{apns}]` | none | legacy 200 stub |

Account registration runs the same validation dance the Go backend does:
refresh OAuth tokens, GET `/api/v1/me`, verify username matches what the
client sent, then persist + associate.

## Background polling

The cron trigger runs `*/1 * * * *` (every minute). On each tick:

1. Pull the `POLL_MAX_ACCOUNTS` (default 10) least-recently-checked accounts
   from D1.
2. For each account:
   - Refresh the OAuth token if it's within 60 seconds of expiry; persist
     the new access/refresh pair.
   - GET `/message/unread.json?before=<last_message_id>` with the account's
     access token.
   - Dedup the returned `thing.fullname`s against the `seen_messages` table.
   - For each new item, build the right APNs payload (`inbox-comment-reply`,
     `inbox-private-message`, `inbox-username-mention-no-context`) and push
     to every device associated with that account.
   - On `BadDeviceToken` / `Unregistered`, delete the device row immediately.
   - Mark every returned id as seen and advance `last_message_id` to the
     newest.
3. Once per hour, trim `seen_messages` rows older than `SEEN_TTL_SECONDS`
   (default 30 days).

Outbound `fetch()` from Workers automatically negotiates HTTP/2 to
api.sandbox.push.apple.com / api.push.apple.com — no special HTTP/2 client
needed.

## Prerequisites

- Node 18+ (for `npx wrangler`)
- `jq` (`brew install jq`) — used by `deploy.sh` to read `wrangler d1 info --json`
- A Cloudflare account (free tier is fine — sign up at https://dash.cloudflare.com)
- An Apple Developer account ($99/yr) with:
  - An **APNs Auth Key** (.p8 file) generated under
    [Certificates, IDs & Profiles → Keys](https://developer.apple.com/account/resources/authkeys/list)
  - The **Team ID** (10-char) — already populated in [wrangler.toml](wrangler.toml)
  - The **Key ID** (10-char, matches the .p8 filename)
- A signed Apollo-Reborn build with `aps-environment` entitlement
  (see [../../SIDELOAD-GUIDE.md](../../SIDELOAD-GUIDE.md))
- Per-account Reddit OAuth app credentials — one Reddit account ≠ one OAuth
  app on the new tweak. Each user creates their own at
  https://www.reddit.com/prefs/apps with `redirect_uri = apollo://reddit-oauth`.

## Deployment

```bash
cd deploy/cloudflare-workers
./deploy.sh
```

`deploy.sh` is fully idempotent. On first run it:

1. Installs npm dependencies (`hono`, `wrangler`, `@cloudflare/workers-types`).
2. Runs `wrangler login` if needed.
3. Creates the D1 database `apollo-reborn-notifications` (or reuses an existing one).
4. Patches `wrangler.toml` with the new `database_id`.
5. Applies [schema.sql](schema.sql) to the remote D1.
6. Prompts for and registers three secrets:
   - `APPLE_KEY_PEM` — raw .p8 file contents (auto-detected at
     `~/Code/side/ios/AuthKey_S74P382FAK.p8` if present)
   - `APPLE_KEY_ID` — 10-char key id (e.g. `S74P382FAK`)
   - `REGISTRATION_SECRET` — generates a fresh base64-url 32-byte token if you
     don't supply one; **save the printed value** — you'll paste it into the
     tweak
7. Runs `wrangler deploy`.

When it finishes you'll have a URL like
`https://apollo-reborn-notifications.<your-account>.workers.dev`. In Apollo:

- **Settings → Custom API → Notification Backend → URL**: that URL
- **Settings → Custom API → Notification Backend → Registration Token**: the
  `REGISTRATION_SECRET` value printed by `deploy.sh`

Then test:

```bash
REGISTRATION_SECRET=<token> ./verify.sh
```

## Configuration

Edit [wrangler.toml](wrangler.toml) `[vars]`:

| Var | Purpose |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer Team ID (10 chars) |
| `APPLE_APNS_TOPIC` | Your sideloaded bundle ID (e.g. `com.mikefelder.apollo`) |
| `APPLE_APNS_SANDBOX` | `true` for dev-signed sideloads, `false` for App Store builds |
| `REDDIT_USER_AGENT` | Fallback UA if a request body doesn't include one — must contain `(by /u/<name>)` |
| `POLL_MAX_ACCOUNTS` | Accounts processed per cron tick (single-user: 10 is plenty) |
| `SEEN_TTL_SECONDS` | How long `seen_messages` rows linger (default 30 days) |

After changing `[vars]`, run `npx wrangler deploy` to apply.

## Local development

```bash
npm install
npm run dev    # wrangler dev — local worker, remote D1
```

`wrangler dev` proxies D1 to the deployed remote database by default; pass
`--local` to use a local SQLite stub instead.

## Tearing down

```bash
./teardown.sh
```

Deletes the worker and the D1 database. You'll be asked to retype the worker
name to confirm.

## File layout

```
deploy/cloudflare-workers/
├── README.md                  this file
├── deploy.sh                  idempotent bootstrap script
├── verify.sh                  smoke test
├── teardown.sh                delete worker + D1 (confirms first)
├── package.json               hono + wrangler + workers-types
├── tsconfig.json              strict + ES2022 + bundler resolution
├── wrangler.toml              CF Worker config — bindings, cron, vars
├── schema.sql                 D1 schema (devices, accounts, device_accounts, seen_messages)
└── src/
    ├── index.ts               entrypoint: { fetch, scheduled }
    ├── types.ts               Env + wire types + D1 row types
    ├── auth.ts                timing-safe registration token comparison
    ├── db.ts                  D1 query helpers (parameterized)
    ├── apns.ts                Web Crypto ES256 JWT signer + HTTP/2 push
    ├── reddit.ts              OAuth token refresh + /api/v1/me + unread inbox
    ├── notifications.ts       APNs payload builders (matches Apollo categories)
    ├── router.ts              Hono routes
    └── poll.ts                cron handler
```

## What's intentionally not implemented

- **Subreddit watchers / trending / username watchers** — these require
  continuous polling of `/r/<sub>/new` for every watched subreddit, plus
  matching logic against per-account regex/keyword rules. Out of scope for
  an MVP. Endpoints return 200/empty so the tweak doesn't error.
- **Live Activities (ActivityKit)** — POST `/v1/live_activities` returns 200
  but the worker doesn't track the thread or push updates. The tweak will
  register thread IDs and they'll just sit there.
- **In-app purchase receipt validation** — `/v1/receipt[/{apns}]` returns
  empty 200, matching the Go backend's stub behavior.

## Security notes

- `REGISTRATION_SECRET` is the only thing standing between the public worker
  URL and someone registering arbitrary Reddit OAuth credentials. Generate a
  fresh one per deployment (32 bytes from `crypto.randomBytes`). The
  registration middleware uses timing-safe comparison.
- Reddit OAuth credentials (`reddit_client_id` / `reddit_client_secret`) are
  stored in D1 *per account*. The tweak sends them in registration bodies.
  D1 is encrypted at rest by Cloudflare; access requires the worker's
  binding (no external connection string).
- `APPLE_KEY_PEM` lives only as a `wrangler secret` — never written to the
  D1 database, never exposed to a fetch route. Cached as a non-extractable
  `CryptoKey` after the first import.
- The worker URL itself is public. The destructive public endpoints (DELETE
  device / DELETE account-link) don't require auth — same model as
  apollo-backend, since knowing your own APNs token is already sensitive.
  If this concerns you, gate those too by adding the registration middleware
  to the corresponding routes in `router.ts`.
