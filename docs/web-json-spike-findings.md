# Web JSON spike — findings & go/no-go (June 12, 2026)

Spike for the OAuth-free escape hatch: drive `www.reddit.com/...json` with a
WebView-harvested session cookie instead of `oauth.reddit.com` + bearer tokens
(the Hydra recovery model), against the day Reddit revokes the remaining API
keys with no path to new ones. Everything below was measured live in the iOS 26
simulator (`scripts/run-in-sim.sh`, signed-in account) on a residential
network.

## Code state & how to exercise it (for a handoff)

All spike code is **uncommitted in the working tree on `main`** (not yet a
branch/PR). New: `src/ApolloWebJSON.{h,m}`,
`src/ApolloWebSessionLoginViewController.{h,m}`. Modified: `Makefile` (file
registration), `src/Tweak.xm` (rewrite splice in the
`oauth.reddit.com || www.reddit.com` branch + `%ctor` hydration),
`src/ApolloState.{h,m}` + `src/UserDefaultConstants.h` (flag + cookie globals),
`src/CustomAPIViewController.m` (settings switch + login row). Grep `[WebJSON]`
and `WebJSON` to find every touch point.

To reproduce (simulator, per CLAUDE.md): `scripts/run-in-sim.sh` to build+launch
injected; in Apollo → Settings → Apollo Reborn → API Keys, toggle **Web JSON
Mode (Experimental)** on, then **Web Session Login (Experimental)** to harvest a
cookie. Watch the flow with the `apollofix` os_log subsystem
(`xcrun simctl spawn "$(cat .sim/device.txt)" log show --last 2m --predicate 'subsystem == "apollofix"' | grep WebJSON`).
**Important:** the spike only browses on an Apollo that already has an OAuth
credential (a restored account *or* a configured API key) — see the cold-start
caveat. Test against a `--backup` that signs you in, not a keyless install.

## TL;DR — GO (transport proven, cheaply)

Both load-bearing unknowns resolved in favor of the migration:

1. **Apollo parses Reddit's web listing JSON as-is.** With the flag on,
   `oauth.reddit.com/hot.json` and `/r/pics/hot.json` were rewritten to
   `www.reddit.com` equivalents and the feed rendered **fully and correctly**
   (posts, thumbnails, flairs, vote counts, subreddit header) with **zero
   response transformation**. Both hosts speak the same
   `{kind, data: {children, after}}` shape; the feared per-endpoint transform
   layer is unnecessary for listings.
2. **Cookie auth survives Apollo's request path.** A `Cookie:` header set
   explicitly in the `__NSCFLocalSessionTask _onqueue_resume` chokepoint
   (Authorization stripped, `HTTPShouldHandleCookies = NO`) authenticated
   cleanly — HTTP 200 + personalized content through RDKClient's
   AFNetworking session, no serializer complaints.

## What was built (flag-gated, dormant by default)

- `src/ApolloWebJSON.{h,m}` — `ApolloWebJSONRewriteRequest()`: whitelist-gated
  rewrite (front page + `/r/<sub>` + sorts `hot|new|top|rising|best|controversial`,
  GET only), ensures `.json` path suffix, strips `Authorization`, attaches
  `sWebSessionCookieHeader`, keeps the custom User-Agent. Spliced as an
  early-return into the existing `oauth.reddit.com || www.reddit.com` branch in
  `src/Tweak.xm` (mirrors the notification-backend splice).
- `src/ApolloWebSessionLoginViewController.{h,m}` — WKWebView login at
  `https://www.reddit.com/login` on the **persistent** data store. Auth state is
  decided by an `/api/me.json` probe (`callAsyncJavaScript` in the page world),
  **not** by cookie presence — see "Login/harvest details" below for why. On an
  existing session it prompts *Keep Current Session / Re-authenticate / Cancel*;
  Re-authenticate clears `.reddit.com` cookies and reloads so the login form
  actually appears. Once a probe (run on `didFinishNavigation` + a 2s poll, since
  the login form submits via fetch with no navigation) reports a logged-in user,
  it harvests all `.reddit.com` cookies into a `name=value; …` header, rewrites
  session-only cookies to ~10,000-day expiry, persists, and dismisses.
- Settings (`CustomAPIViewController`, API Keys section): "Web JSON Mode
  (Experimental)" switch + "Web Session Login (Experimental)" row (visible only
  while the mode is on).
- Flag `UDKeyWebJSONEnabled` (default NO) + `sWebJSONEnabled` /
  `sWebSessionCookieHeader` globals hydrated in `%ctor`. Cookie header persists
  in `standardUserDefaults` — **spike-grade; a real build moves it to the
  keychain** (it's a full account credential).

Flag OFF (the shipped default) was regression-tested: zero `[WebJSON]`
activity, stock oauth behavior byte-for-byte (the helper returns nil before
touching the request).

## Measured results per endpoint

| Request | Unauthenticated | With harvested cookie |
|---|---|---|
| `www.reddit.com/hot.json` (front page) | **403** — Reddit's ~190 KB HTML block page | **200**, feed renders, personalized |
| `www.reddit.com/r/pics/hot.json` | **403** (same block page, also via curl) | **200**, full subreddit renders |
| `www.reddit.com/.json`, `/r/apple/new.json` (curl, browser UA) | **403** | not separately tested (same gate) |

**Unauthenticated web JSON is dead across the board** — not just
`/api/info.json` as previously observed (`Tweak.xm` Recently Read comment).
Reddit now serves its block page to all anonymous `...json` requests
regardless of User-Agent. There is no anonymous fallback tier; the cookie
login is a hard prerequisite, not an enhancement. Apollo degrades gracefully
on the 403 (keeps cached content; AFNetworking rejects the HTML body without
crashing).

### Login/harvest details

- **Auth state is detected via `/api/me.json`, not cookie names.** This was a
  late but important correction. Cookie *presence* is unreliable on two counts:
  (1) Reddit sets `reddit_session` **and** `token_v2` for *anonymous* web
  sessions too, so neither name proves you're logged in; (2) `WKHTTPCookieStore
  getAllCookies` can return an empty/stale snapshot in the moments right after
  the WKWebView is created, even while the network stack already has the
  persisted cookies (so `/login` silently re-authenticates). The login VC now
  runs `fetch('/api/me.json')` via `callAsyncJavaScript` in the page's content
  world (httpOnly cookies included) and keys all decisions on whether that
  returns a username. This is the same signal a future write/identity layer
  needs anyway.
- The login form submits via fetch with no page navigation, so a 2-second poll
  (re-running the probe) — not `didFinishNavigation` — is what catches the
  moment auth completes. Harvest yielded 10–13 cookies (`reddit_session`,
  `token_v2`, `loid`, `csrf_token`, `edgebucket`, …); the serialized header is
  ~2.7 KB and `/api/me.json` confirmed it authenticates as the real account.
- The persistent `WKWebsiteDataStore` retained the session across an app
  **uninstall** in the simulator — the default data store lives outside the app
  container. Treat the WebView cookie store as a credential cache with its own
  lifecycle. "Web Session Login" now detects an existing session up front and
  prompts **Keep Current Session / Re-authenticate / Cancel**; Re-authenticate
  clears all `.reddit.com` cookies so the login form actually appears instead of
  auto-logging-in. (Verified live: prompt named `u/ClydeDroid`; Re-authenticate
  surfaced the real Log In form.)
- old.reddit cookie naming (iOS < 16 path) was not exercised — flagged in the
  VC as a thing to record when first tested on an old-iOS device.

### Cold-start caveat (confirmed by experiment)

On a **truly fresh install — no API keys, no account, no backup** — enabling
Web JSON mode and harvesting a cookie does **not** make the feed load. Apollo's
request pipeline is gated on obtaining an OAuth credential first: it fires
`www.reddit.com/api/v1/access_token` (which needs a configured API client ID),
and with none it never mints a token, never issues the `hot.json` listing
request, and the spinner never resolves — so there's nothing at the chokepoint
for the rewrite to intercept (`[WebJSON] Rewrote` never logs). The harvested
cookie is valid but inert. **Web JSON mode is a transport layer on top of an
Apollo that already believes it's authenticated** (restored account *or*
configured API key); making it work from a keyless cold start is exactly the
deferred "identity integration" item below — the gate on shipping.

### Response-shape diff

None observed for listings. `RDKClient objectsFromListingResponse:` logged no
non-dict warnings; every visible feed element (including vote arrows/scores,
NSFW-blurred thumbnails, flair pills) populated. Auth-state-dependent fields
(`likes`, `saved`, `over_18` gating) rendered consistent with the signed-in
account because the cookie session is that account. No transformer was built —
correctly, per plan.

## Deferred work — sizing the full migration

The spike proves the transport. A real "Reddit killed our keys" build needs,
in rough ascending order of risk:

1. **Whitelist → full read coverage** (S–M). Extend the path whitelist to
   comments (`/r/<sub>/comments/<id>.json`), user pages, search, multis,
   subscriptions (`/subreddits/mine`), inbox. Each is the same mechanical
   rewrite; the work is enumerating Apollo's endpoints (all flow through the
   same chokepoint, so it's whitelist + spot-check per endpoint, not new
   plumbing). Inbox/messaging shapes are the most likely to need a transform.
2. **Write actions via modhash** (M). Vote/comment/submit/save POST to
   `www.reddit.com/api/...` with `X-Modhash` (harvested from `/api/me.json`,
   NOT a cookie) + the session cookie, instead of bearer-authed oauth calls.
   `RDKClient.modhash` already exists (`Headers/ObjC/RDKClient.h:23`) —
   RedditKit predates OAuth-only Reddit and retains its modhash plumbing,
   which may make this mostly a request-rewrite problem too. Risk: Reddit's
   web-side ratelimiting/captcha on writes.
3. **Identity integration** (M–L, the real lift). Today Apollo still believes
   the OAuth account it's signed into; the cookie just happens to be the same
   user. Without keys, `AccountManager`/Valet (`2RedditAccounts2`), token
   refresh, and the app-only session all break. The cookie session must
   synthesize or bypass that: fake `RDKOAuthCredential`/account entries keyed
   off the cookie login, suppress token-refresh calls, map `/api/me.json` to
   the account object. This is RE-heavy (AccountManager is Swift) and is the
   gate on shipping; everything else is plumbing.
4. **Session lifecycle** (S). Detect cookie expiry/revocation (403/redirect on
   a previously-good endpoint), surface a "session expired — sign in again"
   prompt, and re-harvest. Keychain storage for the cookie header. Hydra's
   far-future-expiry trick is already implemented in the login VC.

Estimate: **1–2 weeks of focused work to a usable read+write client riding on
cookie auth, dominated by item 3.** No architectural unknowns remain — the
chokepoint handles 100% of Reddit traffic, and the response format needs no
adaptation for the core browse surface.

## Gotchas recorded for the next person

- Set the `Cookie` header explicitly on the request; do not trust the session
  cookie jar (RDKClient's AFHTTPSessionManager config is an unknown, and
  `HTTPShouldHandleCookies = NO` also prevents the jar from overwriting it).
- Reddit's 403 block page is ~190 KB of HTML with `Content-Type: text/html` —
  cheap to detect for the session-expiry check (item 4).
- In the simulator workflow, `scripts/run-in-sim.sh` with a `.sim/backup.zip`
  present wipes the app container on every launch (uninstall → reinstall →
  preload) — move the zip aside while iterating on state you want to keep,
  e.g. a harvested cookie session.
