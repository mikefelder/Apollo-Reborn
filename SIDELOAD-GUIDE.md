# Sideloading Apollo Reborn with Your Own Apple Developer Account

End-to-end guide for building, rebranding, signing, and installing Apollo Reborn
on a physical iOS device using a **paid Apple Developer account** (Team ID + 7
explicit App IDs + Push entitlement). This is the path that gets you:

- A custom bundle ID (e.g. `com.you.apollo`) you control
- All six app extensions intact (share sheet, widgets, Safari extension, notification service, etc.)
- 1-year install validity (no 7-day free-account expiry)
- The `aps-environment` entitlement, so push notifications work if you also stand up the [self-hosted backend](https://github.com/Apollo-Reborn/apollo-backend)

If you only want the no-extensions, 7-day, free-account flow, use AltStore /
SideStore against `Apollo-Reborn-*-NOEXTENSIONS.ipa` from the releases page and
stop reading.

---

## What you'll end up with

```
packages/Apollo-Reborn-Injected.ipa     <- tweak injected, bundle id still com.christianselig.Apollo
packages/Apollo-Reborn-Rebranded.ipa    <- bundle id rewritten to YOUR id (app + 6 appexes)
packages/Apollo-Reborn-AppleSigned.ipa  <- signed with your Apple Development cert + 7 profiles
```

The final `AppleSigned` IPA installs in-place over any previous build without
losing data (Apollo stores everything in the App Group, not the bundle).

---

## Prerequisites

### Apple side

- **Paid Apple Developer Program membership** ($99/yr). Free Apple IDs cannot enable Push.
- **Team ID** (10-char string, e.g. `ABCDE12345`) — find at https://developer.apple.com/account → Membership.
- **An iOS device** registered to that team at https://developer.apple.com/account/resources/devices/list (just its UDID — get with `xcrun devicectl list devices` or Finder → iPhone → click serial number to reveal UDID).

### Mac side

```bash
# Xcode Command Line Tools (provides codesign, security, devicectl, PlistBuddy)
xcode-select --install

# ldid — required by Theos for tweak signing
brew install ldid

# Theos — the iOS tweak build framework
git clone --recursive https://github.com/theos/theos /Users/$USER/theos
echo 'export THEOS=$HOME/theos' >> ~/.zshrc
source ~/.zshrc
```

Verify:

```bash
[ -d "$THEOS/makefiles" ] && echo "OK: Theos at $THEOS" || echo "MISSING: Theos"
command -v ldid && command -v codesign && command -v xcrun
```

### One source IPA

You need a **decrypted** Apollo `.ipa` to inject into. The repo conventionally
calls this `Apollo-base.ipa` (see [AGENTS.md](AGENTS.md)). If you have an
existing Apollo Reborn release IPA like `Apollo-Reborn-3.1.1-GLASS.ipa`, that
also works as input — `build-ipa.sh` will re-inject the latest tweak `.deb` into
it.

> Decryption of an App Store IPA is outside this guide's scope. Common paths:
> dump from a jailbroken device, use `frida-ios-dump`, or grab a community-shared
> decrypted base IPA from a trusted Discord / sideloading forum.

---

## Phase 1 — Build the tweak

From the repo root:

```bash
# Pull submodules (FFmpegKit, ZipArchive, FLEXing)
git submodule update --init --recursive

# Build the .deb
THEOS=/Users/$USER/theos make package
```

Output:

```
packages/com.apollo.reborn_<version>+debug_iphoneos-arm.deb
```

If `make` fails with "common.mk not found", `$THEOS` isn't set in the shell
running `make`. Pass it inline as shown above.

---

## Phase 2 — Inject the tweak into the IPA

```bash
./build-ipa.sh \
  --ipa  ./Apollo-base.ipa \
  --deb  ./packages/com.apollo.reborn_*.deb \
  -o     ./packages/Apollo-Reborn-Injected.ipa
```

`build-ipa.sh` prefers the repo-local injector in
[scripts/inject-deb-local.sh](scripts/inject-deb-local.sh) (handles
already-injected base IPAs) and falls back to `azule` / `cyan` for stock IPAs.

Sanity check the injected payload:

```bash
unzip -l packages/Apollo-Reborn-Injected.ipa | grep -E 'ApolloReborn\.dylib|CydiaSubstrate'
```

You should see both `Frameworks/ApolloReborn.dylib` and
`Frameworks/CydiaSubstrate.framework/CydiaSubstrate`.

---

## Phase 3 — Register App IDs at the Apple Developer Portal

This is the **most tedious phase** and the place that bites every first-timer.
Apollo ships **6 app extensions**, and each one needs its own explicit App ID
under your team. Wildcard App IDs (`TEAMID.*`) **cannot** enable Push, so the
main app needs its own explicit ID too. That's **7 App IDs total**.

### 3.1 Pick your bundle ID prefix

Pick a reverse-DNS string you control, e.g. `com.you.apollo`. Throughout this
guide that string is referenced as **`<your-base>`**.

> **Do NOT use `com.christianselig.Apollo`.** It's globally owned by Christian's
> team and Reddit's edge WAF blocks any User-Agent containing it.

### 3.2 Register the 7 App IDs

Go to https://developer.apple.com/account/resources/identifiers/list → **+** → **App IDs** → **App**.

For each row below: pick **Explicit** Bundle ID, set Description to anything
sensible (e.g. "Apollo Reborn Main"), enter the bundle ID, and toggle the
capabilities listed.

| # | Bundle ID | Capabilities to enable |
|---|---|---|
| 1 | `<your-base>` | **Push Notifications**, **iCloud** (Include CloudKit support) |
| 2 | `<your-base>.ApolloIntents` | (none required) |
| 3 | `<your-base>.Apollofari` | (none required — Safari Web Extension) |
| 4 | `<your-base>.AthenaWidget` | (none required) |
| 5 | `<your-base>.NotificationContentExtension` | (none required) |
| 6 | `<your-base>.NotificationServiceExtension` | (none required) |
| 7 | `<your-base>.OpenInUIExtension` | (none required) |

> **App Groups warning.** Apollo's source code hardcodes the App Group
> `group.com.christianselig.apollo` (read in
> [src/CustomAPIViewController.m](src/CustomAPIViewController.m) "no matter
> the bundle ID"). You **cannot register that group** under your own team
> because it's owned by Christian's team. Two options:
>
> - **Option A (recommended, what this guide does):** skip App Groups entirely
>   on all 7 App IDs. You sacrifice widget state-sharing and rich-content NSE
>   parsing, but everything else works.
> - **Option B:** patch the source to use `group.<your-base>` and register that
>   group on every App ID. Out of scope here.

> **iCloud container.** When you enable iCloud on App ID #1, click **Edit** →
> **iCloud** → **Configure** → create a new container `iCloud.<your-base>` and
> tick it. Skip for App IDs #2-7.

### 3.3 Create one Provisioning Profile per App ID

https://developer.apple.com/account/resources/profiles/list → **+** → **iOS App Development** → **Continue**.

For each of the 7 App IDs:

1. Pick the App ID from the dropdown
2. Pick your Apple Development certificate
3. Pick your device(s)
4. Name the profile clearly (e.g. `Apollo_Main_Dev`, `Apollo_AthenaWidget_Dev`, etc.)
5. Generate → **Download**

Save all 7 `.mobileprovision` files into a single directory, e.g.:

```bash
mkdir -p ~/Code/side/ios/profiles
mv ~/Downloads/Apollo_*.mobileprovision ~/Code/side/ios/profiles/
```

Verify each profile's bundle binding:

```bash
for p in ~/Code/side/ios/profiles/*.mobileprovision; do
  tmp=$(mktemp)
  security cms -D -i "$p" > "$tmp" 2>/dev/null
  appid=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$tmp" 2>/dev/null)
  apse=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$tmp" 2>/dev/null)
  printf '%-50s -> %s  aps=%s\n' "$(basename "$p")" "$appid" "${apse:-none}"
  rm -f "$tmp"
done
```

Expected output: 7 lines, one per profile, with **`aps=development`** on the
main app's profile and `aps=none` on the six appex profiles.

---

## Phase 4 — Rebrand the IPA

Rewrites `CFBundleIdentifier` on the app and each `.appex` from
`com.christianselig.Apollo[.suffix]` to `<your-base>[.suffix]`, and strips
existing `_CodeSignature` directories so the next signer reseals cleanly.

```bash
./scripts/rebrand-ipa.sh \
  ./packages/Apollo-Reborn-Injected.ipa \
  <your-base> \
  -o ./packages/Apollo-Reborn-Rebranded.ipa
```

Verify all 7 bundle IDs were rewritten:

```bash
tmpdir=$(mktemp -d)
unzip -q packages/Apollo-Reborn-Rebranded.ipa -d "$tmpdir"
app=$(find "$tmpdir/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)
echo "App: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
echo "Appexes:"
for ax in "$app"/PlugIns/*.appex; do
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ax/Info.plist"
done
rm -rf "$tmpdir"
```

Should output `<your-base>` followed by 6 lines of `<your-base>.<Suffix>`.

> **What rebrand does NOT touch (on purpose):**
> - The App Group `group.com.christianselig.apollo` (Apollo's binary still reads it)
> - The `apollo://` URL scheme (literal in `CFBundleURLTypes`, share action still routes correctly)
> - `com.christianselig.Apollo.StateRestoration.activity`, keychain/Valet service names

---

## Phase 5 — Sign the IPA with your Apple Development cert

[`scripts/resign-ipa-codesign.sh`](scripts/resign-ipa-codesign.sh) uses
Apple's `codesign` (not `zsign`) so the appex executables get the
`CS_EXECSEG_MAIN_BINARY` flag that iOS 26 AMFI requires. With
`--profile-dir` it auto-matches each bundle to the right `.mobileprovision` by
comparing `application-identifier` suffixes.

First, find your signing identity:

```bash
security find-identity -v -p codesigning
```

Look for `"Apple Development: Your Name (XXXXXXXXXX)"`. Copy the full quoted
string.

Then sign:

```bash
./scripts/resign-ipa-codesign.sh \
  ./packages/Apollo-Reborn-Rebranded.ipa \
  "Apple Development: Your Name (XXXXXXXXXX)" \
  --profile-dir ~/Code/side/ios/profiles \
  -o ./packages/Apollo-Reborn-AppleSigned.ipa
```

You should see in the output:

```
  sign appex (w/ provisioned entitlements): PlugIns/ApolloIntents.appex
  sign appex (w/ provisioned entitlements): PlugIns/Apollofari.appex
  sign appex (w/ provisioned entitlements): PlugIns/AthenaWidgetExtension.appex
  sign appex (w/ provisioned entitlements): PlugIns/NotificationContentExtension.appex
  sign appex (w/ provisioned entitlements): PlugIns/NotificationServiceExtension.appex
  sign appex (w/ provisioned entitlements): PlugIns/OpenInUIExtension.appex
  sign app  (w/ provisioned entitlements): Apollo.app
Verifying…
  Apollo.app: valid on disk
  Apollo.app: satisfies its Designated Requirement
Re-signed IPA: packages/Apollo-Reborn-AppleSigned.ipa
```

If you see `WARNING: no profile in ... matches bundle id '...'`, you have a
missing or wrong-bundle-ID profile in the directory. Re-check Phase 3.

### Confirm the Push entitlement made it in

```bash
tmpdir=$(mktemp -d)
unzip -q packages/Apollo-Reborn-AppleSigned.ipa -d "$tmpdir"
app="$tmpdir/Payload/Apollo.app"
echo "=== Main app entitlements ==="
/usr/bin/codesign -d --entitlements :- "$app" 2>/dev/null | \
  grep -E 'aps-environment|application-identifier|team-identifier|get-task-allow'
rm -rf "$tmpdir"
```

Must show:

```
<key>aps-environment</key><string>development</string>
<key>application-identifier</key><string>TEAMID.your-base</string>
<key>com.apple.developer.team-identifier</key><string>TEAMID</string>
<key>get-task-allow</key><true/>
```

If `aps-environment` is missing, your main App ID didn't have Push enabled or
the wrong profile got matched.

---

## Phase 6 — Install on your device

> **Critical: install the AppleSigned IPA directly. Do NOT re-sign through
> Sideloadly/AltStore** — they'd undo the iOS-26 appex main-binary flag and the
> share extension will silently break.

Get your device's UUID once (note: this is the **xcrun identifier**, not the
hardware UDID — `devicectl` uses its own GUIDs):

```bash
xcrun devicectl list devices
# copy the IDENTIFIER column for your iPhone
```

Uninstall any previous Apollo build to avoid `apollo://` scheme collisions:

```bash
# Original Apollo
xcrun devicectl device uninstall app --device <device-id> com.christianselig.Apollo 2>/dev/null || true

# Any previously-installed sideload under a different bundle ID
xcrun devicectl device uninstall app --device <device-id> <prev-base> 2>/dev/null || true
```

Install:

```bash
xcrun devicectl device install app \
  --device <device-id> \
  ./packages/Apollo-Reborn-AppleSigned.ipa
```

Output should include `App installed:` and your new bundle ID.

---

## Phase 7 — First-launch configuration in the app

Apollo will need Reddit + (optionally) Imgur + (optionally) Giphy API keys
because Christian's API keys went dark. The settings are at
**Settings → Apollo Reborn → Custom API**.

### 7.1 Reddit (required — without this you can't log in)

Reddit no longer allows new API key creation. The community workaround is to
piggyback on Dystopia's accessibility-exempt Client-ID:

1. Install [Dystopia for Reddit](https://apps.apple.com/us/app/dystopia-for-reddit/id1430599061) from the App Store
2. Log into Reddit inside Dystopia
3. Reddit emails you the **Client ID** (a ~20-char string) at the email on your Reddit account
4. In Apollo: **Settings → Custom API**:
   - **Reddit API Key**: the Client ID from the email
   - **Reddit API Secret**: leave **blank** (Dystopia is registered as an installed app)
   - **Redirect URI**: `dystopia://response`
   - **User Agent**: `ios:com.CarbonDev.Dystopia:v1.0.1(by /u/DystopiaForReddit)`
5. Back out to **Settings → Reddit Accounts → Add Account** to log in

> All four fields must be exact. Reddit's OAuth server rejects mismatched
> `redirect_uri` silently with a generic "authentication failed" toast; the
> User Agent string is enforced by Reddit's API rules and mismatches get
> rate-limited under Dystopia's reputation.

### 7.2 Giphy (optional — enables the in-comment GIF picker)

Giphy still issues keys freely (unlike Reddit/Imgur):

1. https://developers.giphy.com/dashboard/ → sign up → **Create an App** → pick **SDK** (auto-approved)
2. Copy the API Key
3. **Settings → Custom API → Giphy API Key** → paste

Powers the GIF button in the comment compose toolbar. Without it the button
opens a "configure API key" alert.

### 7.3 Imgur (optional — enables Imgur uploads + album rendering)

Imgur no longer issues new keys easily. Try https://api.imgur.com/oauth2/addclient
("Anonymous usage without user authorization"). If rejected, you can either
share an existing Client-ID or skip the field — switch
**Settings → Custom API → Media Upload Host** to **Reddit** to host uploads on
`i.redd.it` instead. Apollo Reborn defaults to Imgur as the upload host.

---

## Phase 8 (optional) — Self-hosted push notifications

Apollo's original push backend went dark June 2023. The tweak rewrites all
requests to it. If you want push back, run a self-hosted instance of
[Apollo-Reborn/apollo-backend](https://github.com/Apollo-Reborn/apollo-backend)
and configure:

- **Settings → Custom API → Notification Backend → Backend URL**: `https://your-backend.example.com`
- **Settings → Custom API → Notification Backend → Registration Token**: matches `REGISTRATION_SECRET` env var

You'll also need an **APNs auth key (`.p8`)** from
https://developer.apple.com/account/resources/authkeys/list (one-time download)
to bake into the backend's `secrets/apple.p8`.

See the backend's own [GETTING_STARTED.md](https://github.com/Apollo-Reborn/apollo-backend/blob/main/GETTING_STARTED.md)
for the full deployment recipe (docker-compose quickstart, env vars, end-to-end
test push verification). Set `APPLE_APNS_SANDBOX=true` because dev-signed builds
register with the APNs sandbox gateway — without this you'll get `BadDeviceToken`
and the backend's worker will aggressively auto-delete your device row.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Install fails with "could not install" | Stale `apollo://` scheme owner from a previous build | Uninstall both `com.christianselig.Apollo` and any prior `<your-base>` first |
| Share extension ("Open in Apollo") does nothing | IPA was re-signed through Sideloadly/AltStore which dropped the appex main-binary flag | Re-run Phase 5 directly and install the codesign output without re-signing |
| `WARNING: no profile in ... matches bundle id '...'` during signing | Missing or misnamed profile for one of the 7 App IDs | Re-check Phase 3.3; verify with the `for p in ...` loop |
| `aps-environment` missing from `codesign -d --entitlements` output | Main App ID didn't have Push enabled, or wrong profile matched | Enable Push on App ID #1, regenerate that profile, re-run Phase 5 |
| `App Groups` error when generating a profile | You tried to add `group.com.christianselig.apollo` to your App ID | Use Option A — skip App Groups entirely (Phase 3.2) |
| Reddit login fails with "authentication failed" | Redirect URI / User Agent / Client ID mismatch | Re-check Phase 7.1 — all four must be exact |
| App crashes on launch ("AMFI: constraint violation") | An appex still has `zsign`-style signature without `MAIN_BINARY` flag | Confirm Phase 5 used `codesign` from Xcode CLT (not zsign) — check `which codesign` |
| Push notifications never arrive | Either no backend, wrong sandbox flag, or wrong APNs topic | See Phase 8; `APPLE_APNS_SANDBOX=true` and `APPLE_APNS_TOPIC=<your-base>` |

---

## Upgrading to a new release later

Once everything's set up, repeat builds are short:

```bash
# 1. Pull latest source
git pull && git submodule update --recursive

# 2. Rebuild tweak
THEOS=/Users/$USER/theos make package

# 3. Re-inject, re-rebrand, re-sign
./build-ipa.sh --ipa ./Apollo-base.ipa --deb ./packages/com.apollo.reborn_*.deb \
  -o ./packages/Apollo-Reborn-Injected.ipa
./scripts/rebrand-ipa.sh ./packages/Apollo-Reborn-Injected.ipa <your-base> \
  -o ./packages/Apollo-Reborn-Rebranded.ipa
./scripts/resign-ipa-codesign.sh ./packages/Apollo-Reborn-Rebranded.ipa \
  "Apple Development: Your Name (XXXXXXXXXX)" \
  --profile-dir ~/Code/side/ios/profiles \
  -o ./packages/Apollo-Reborn-AppleSigned.ipa

# 4. Install in-place (Apollo's data survives because App Group is unchanged)
xcrun devicectl device install app --device <device-id> \
  ./packages/Apollo-Reborn-AppleSigned.ipa
```

Provisioning profiles last **1 year** from creation. When they expire, just
regenerate them at https://developer.apple.com/account/resources/profiles/list
(no need to redo App IDs) and replace the files in `~/Code/side/ios/profiles/`.

---

## Reference

- Tweak source: [src/](src/)
- Build wrappers: [build-ipa.sh](build-ipa.sh), [scripts/inject-deb-local.sh](scripts/inject-deb-local.sh)
- Bundle rewriting: [scripts/rebrand-ipa.sh](scripts/rebrand-ipa.sh)
- Apple-codesign re-signer: [scripts/resign-ipa-codesign.sh](scripts/resign-ipa-codesign.sh)
- Repo conventions: [AGENTS.md](AGENTS.md)
- Distribution flow for maintainers: [DISTRIBUTION.md](DISTRIBUTION.md)
- Push backend: https://github.com/Apollo-Reborn/apollo-backend
