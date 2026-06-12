#import "ApolloWebJSON.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "Defaults.h"

#import <Security/Security.h>

NSString *const ApolloWebJSONSessionExpiredNotification = @"ApolloWebJSONSessionExpiredNotification";
NSString *const ApolloWebJSONSyntheticBearerToken = @"apollo-webjson-cookie-session";

#pragma mark - Keychain-backed credential storage (item 4)

// The harvested cookie header, modhash, and username are full account
// credentials, so they live in the keychain (generic password items) rather
// than NSUserDefaults. In the simulator these Sec* calls hit the virtualized
// keychain installed by Tweak.xm (#if APOLLO_SIM_BUILD), so this path works in
// the sim dev loop too.
// The service string intentionally contains the Apollo base bundle id. On
// device it's just a namespace for our generic-password items. In the simulator
// it's load-bearing: Tweak.xm virtualizes the keychain (Sec* fishhooks) only for
// "Valet queries" — those whose service contains "com.christianselig.Apollo" —
// so an ad-hoc-signed sim app (no keychain entitlement) can read/write here
// without securityd rejecting it with errSecMissingEntitlement (-34018).
static NSString *const kWebJSONKeychainService = @"com.christianselig.Apollo.webjson";
static NSString *const kWebJSONKeychainAccountCookie   = @"sessionCookieHeader";
static NSString *const kWebJSONKeychainAccountModhash  = @"sessionModhash";
static NSString *const kWebJSONKeychainAccountUsername = @"sessionUsername";

static NSString *ApolloWebJSONKeychainRead(NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWebJSONKeychainService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData:  (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st != errSecSuccess || !result) return nil;
    NSData *data = (__bridge_transfer NSData *)result;
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return value.length > 0 ? value : nil;
}

static void ApolloWebJSONKeychainWrite(NSString *account, NSString *value) {
    NSDictionary *match = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWebJSONKeychainService,
        (__bridge id)kSecAttrAccount: account,
    };
    if (value.length == 0) {
        SecItemDelete((__bridge CFDictionaryRef)match);
        return;
    }
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *update = @{ (__bridge id)kSecValueData: data };
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)match, (__bridge CFDictionaryRef)update);
    if (st == errSecItemNotFound) {
        NSMutableDictionary *add = [match mutableCopy];
        add[(__bridge id)kSecValueData] = data;
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    if (st != errSecSuccess) {
        ApolloLog(@"[WebJSON] Keychain write for %@ failed (OSStatus %d)", account, (int)st);
    }
}

#pragma mark - Path classification

typedef NS_ENUM(NSInteger, ApolloWebJSONPathKind) {
    ApolloWebJSONPathUnsupported = 0,
    ApolloWebJSONPathListing,   // page URL — must carry a ".json" suffix
    ApolloWebJSONPathAPI,       // /api/... endpoint — returns JSON natively
};

static NSSet<NSString *> *ApolloWebJSONListingSorts(void) {
    static NSSet<NSString *> *sorts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sorts = [NSSet setWithArray:@[@"hot", @"new", @"top", @"rising", @"best", @"controversial"]];
    });
    return sorts;
}

// User-page "where" segments that follow /user/<name>/ (e.g. /user/x/saved).
static NSSet<NSString *> *ApolloWebJSONUserWheres(void) {
    static NSSet<NSString *> *wheres;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        wheres = [NSSet setWithArray:@[@"overview", @"submitted", @"comments", @"saved",
                                       @"upvoted", @"downvoted", @"hidden", @"gilded", @"posts"]];
    });
    return wheres;
}

// Classify a GET path. Listing pages need a ".json" suffix appended; /api/*
// endpoints serve JSON without one. Anything unrecognized returns Unsupported
// so it stays on the oauth path rather than silently degrading.
static ApolloWebJSONPathKind ApolloWebJSONClassifyReadPath(NSString *path) {
    if (path.length == 0) return ApolloWebJSONPathUnsupported;

    // /api/* (including /api/v1/me, /api/multi/...) returns JSON natively.
    if ([path hasPrefix:@"/api/"]) return ApolloWebJSONPathAPI;

    // Normalize: strip one trailing ".json" and any trailing "/".
    NSString *p = path;
    if ([p hasSuffix:@".json"]) p = [p substringToIndex:p.length - 5];
    while ([p hasSuffix:@"/"] && p.length > 1) p = [p substringToIndex:p.length - 1];

    NSSet<NSString *> *sorts = ApolloWebJSONListingSorts();

    // Front page: "/" or "/<sort>".
    if ([p isEqualToString:@"/"]) return ApolloWebJSONPathListing;
    if (p.length > 1 && [p characterAtIndex:0] == '/' && [sorts containsObject:[p substringFromIndex:1]])
        return ApolloWebJSONPathListing;

    if (![p hasPrefix:@"/"]) return ApolloWebJSONPathUnsupported;
    NSArray<NSString *> *seg = [[p substringFromIndex:1] componentsSeparatedByString:@"/"];
    NSString *head = seg.count > 0 ? seg[0] : @"";

    // Subreddit space: /r/<sub>[/...]
    if ([head isEqualToString:@"r"]) {
        if (seg.count < 2 || seg[1].length == 0) return ApolloWebJSONPathUnsupported;
        if (seg.count == 2) return ApolloWebJSONPathListing;                 // /r/<sub>
        NSString *what = seg[2];
        if ([sorts containsObject:what]) return ApolloWebJSONPathListing;     // /r/<sub>/<sort>
        if ([what isEqualToString:@"comments"]) return ApolloWebJSONPathListing; // /r/<sub>/comments/<id>[/slug]
        if ([what isEqualToString:@"search"]) return ApolloWebJSONPathListing;   // /r/<sub>/search
        if ([what isEqualToString:@"about"]) return ApolloWebJSONPathListing;    // /r/<sub>/about[/...]
        if ([what isEqualToString:@"wiki"]) return ApolloWebJSONPathListing;     // /r/<sub>/wiki/...
        if ([what isEqualToString:@"duplicates"]) return ApolloWebJSONPathListing;
        return ApolloWebJSONPathUnsupported;
    }

    // User space: /user/<name>[/where] or /u/<name>[/where]
    if ([head isEqualToString:@"user"] || [head isEqualToString:@"u"]) {
        if (seg.count < 2 || seg[1].length == 0) return ApolloWebJSONPathUnsupported;
        if (seg.count == 2) return ApolloWebJSONPathListing;                  // /user/<name>
        NSString *what = seg[2];
        if ([ApolloWebJSONUserWheres() containsObject:what]) return ApolloWebJSONPathListing;
        if ([what isEqualToString:@"about"]) return ApolloWebJSONPathListing;
        if ([what isEqualToString:@"m"]) return ApolloWebJSONPathListing;     // /user/<name>/m/<multi> (multireddit)
        return ApolloWebJSONPathUnsupported;
    }

    // Comments by direct id: /comments/<id>[/slug]
    if ([head isEqualToString:@"comments"]) return ApolloWebJSONPathListing;
    if ([head isEqualToString:@"duplicates"]) return ApolloWebJSONPathListing;

    // Global + scoped search.
    if ([head isEqualToString:@"search"]) return ApolloWebJSONPathListing;

    // Subscriptions / subreddit discovery: /subreddits/mine/<where>, /subreddits/<where>.
    if ([head isEqualToString:@"subreddits"]) return ApolloWebJSONPathListing;

    // Inbox / private messages: /message/<where>, /message/messages/<id>.
    if ([head isEqualToString:@"message"]) return ApolloWebJSONPathListing;

    // Account prefs (friends/blocked lists are served here on the web).
    if ([head isEqualToString:@"prefs"]) return ApolloWebJSONPathListing;

    return ApolloWebJSONPathUnsupported;
}

// Whitelist a write (POST/PUT/DELETE). Apollo's write actions all POST to
// oauth.reddit.com/api/<action>; the web mirror at www.reddit.com/api/<action>
// accepts the same body with cookie + modhash auth. We allow the whole /api/
// surface but exclude the OAuth token endpoints (those are the identity layer's
// job, not a content write) and media uploads (multipart, handled elsewhere).
static BOOL ApolloWebJSONWritePathIsRoutable(NSString *path) {
    if (![path hasPrefix:@"/api/"]) return NO;
    if ([path hasPrefix:@"/api/v1/access_token"]) return NO;
    if ([path hasPrefix:@"/api/v1/revoke_token"]) return NO;
    if ([path hasPrefix:@"/api/v1/authorize"]) return NO;
    // Native media uploads go straight to Reddit's media host via the
    // ApolloImageUploadHost path; don't intercept their lease/asset POSTs.
    if ([path hasPrefix:@"/api/media/"]) return NO;
    if ([path isEqualToString:@"/api/v1/media/asset.json"]) return NO;
    return YES;
}

#pragma mark - Request rewrite

NSURLRequest *ApolloWebJSONRewriteRequest(NSURLRequest *request) {
    if (!sWebJSONEnabled || !request) return nil;

    // No session → leave the oauth path untouched. Without the cookie the web
    // host serves its 403 block page, which is strictly worse than oauth.
    if (sWebSessionCookieHeader.length == 0) return nil;

    NSURL *url = request.URL;
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"oauth.reddit.com"] && ![host isEqualToString:@"www.reddit.com"]) return nil;

    NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
    NSString *path = url.path ?: @"/";
    BOOL isWrite = !([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"]);

    ApolloWebJSONPathKind kind = ApolloWebJSONPathUnsupported;
    if (isWrite) {
        if (!ApolloWebJSONWritePathIsRoutable(path)) return nil;
        kind = ApolloWebJSONPathAPI;
    } else {
        kind = ApolloWebJSONClassifyReadPath(path);
        if (kind == ApolloWebJSONPathUnsupported) return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return nil;
    components.host = @"www.reddit.com";

    // Listing/page URLs must carry ".json"; /api endpoints are already JSON.
    if (kind == ApolloWebJSONPathListing) {
        NSString *p = components.path ?: @"/";
        if (![p hasSuffix:@".json"]) {
            while ([p hasSuffix:@"/"] && p.length > 1) p = [p substringToIndex:p.length - 1];
            components.path = [p isEqualToString:@"/"] ? @"/.json" : [p stringByAppendingString:@".json"];
        }
    }

    NSURL *rewrittenURL = components.URL;
    if (!rewrittenURL) return nil;

    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = rewrittenURL;

    // Cookie auth replaces the bearer token outright.
    [mutable setValue:nil forHTTPHeaderField:@"Authorization"];
    // Set the Cookie header explicitly rather than relying on a cookie jar —
    // RDKClient's AFHTTPSessionManager session config may use a non-shared jar,
    // and HTTPShouldHandleCookies=NO stops the session from overriding our
    // header with (or storing) jar cookies.
    [mutable setValue:sWebSessionCookieHeader forHTTPHeaderField:@"Cookie"];
    mutable.HTTPShouldHandleCookies = NO;

    // Writes need the modhash. Reddit's web API accepts it either as the
    // X-Modhash header or a "uh" form field; the header covers both old and new
    // reddit without rewriting the body.
    if (isWrite && sWebSessionModhash.length > 0) {
        [mutable setValue:sWebSessionModhash forHTTPHeaderField:@"X-Modhash"];
    }

    [mutable setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];

    ApolloLog(@"[WebJSON] Rewrote %@ %@ -> %@ (%@%@)",
              method, url.absoluteString, rewrittenURL.absoluteString,
              isWrite ? @"write" : @"read",
              (isWrite && sWebSessionModhash.length > 0) ? @", modhash" : @"");
    return mutable;
}

#pragma mark - Session-expiry detection (item 4)

static BOOL sSessionExpiredAnnounced = NO;

void ApolloWebJSONNoteResponse(NSURLRequest *request, NSURLResponse *response) {
    if (!sWebJSONEnabled || sWebSessionCookieHeader.length == 0) return;
    if (sSessionExpiredAnnounced) return;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return;

    NSURL *url = request.URL;
    if (![url.host.lowercaseString isEqualToString:@"www.reddit.com"]) return;
    // Only react to requests we authenticated with the cookie — those carry the
    // Cookie header we set in ApolloWebJSONRewriteRequest. This skips unrelated
    // www.reddit.com traffic (e.g. the trending-subreddits fetch) that could
    // legitimately 403 with HTML without meaning our session died.
    if ([request valueForHTTPHeaderField:@"Cookie"].length == 0) return;

    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    // Reddit's anonymous block page is HTTP 403 with a ~190 KB text/html body.
    // A live cookie session never sees this on a request we authenticated; when
    // it does, the cookie has expired or been revoked. A 403 with a JSON body
    // (e.g. a private/quarantined subreddit) is a normal per-content error and
    // must NOT trip the expiry path — hence the text/html gate.
    if (http.statusCode != 403) return;
    NSString *contentType = [http.allHeaderFields[@"Content-Type"] lowercaseString] ?: @"";
    if (![contentType containsString:@"text/html"]) return;

    sSessionExpiredAnnounced = YES;
    ApolloLog(@"[WebJSON] Session appears expired — 403 HTML block page for %@", url.absoluteString);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloWebJSONSessionExpiredNotification object:nil];
    });
}

#pragma mark - Credential setters / hydration

void ApolloWebJSONSetSessionCookieHeader(NSString *cookieHeader) {
    if (cookieHeader.length > 0) {
        sWebSessionCookieHeader = [cookieHeader copy];
        // A freshly harvested session is presumed live again.
        sSessionExpiredAnnounced = NO;
    } else {
        sWebSessionCookieHeader = nil;
    }
    ApolloWebJSONKeychainWrite(kWebJSONKeychainAccountCookie, sWebSessionCookieHeader);
}

void ApolloWebJSONSetModhash(NSString *modhash) {
    sWebSessionModhash = modhash.length > 0 ? [modhash copy] : nil;
    ApolloWebJSONKeychainWrite(kWebJSONKeychainAccountModhash, sWebSessionModhash);
}

void ApolloWebJSONSetUsername(NSString *username) {
    sWebSessionUsername = username.length > 0 ? [username copy] : nil;
    ApolloWebJSONKeychainWrite(kWebJSONKeychainAccountUsername, sWebSessionUsername);
}

void ApolloWebJSONLoadPersistedCredentials(void) {
    // One-time migration: the spike persisted the cookie header in
    // standardUserDefaults. Move any legacy value into the keychain, then wipe
    // the defaults copy so the credential no longer sits in a world-readable plist.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id legacy = [defaults objectForKey:UDKeyWebSessionCookieHeader];
    if ([legacy isKindOfClass:[NSString class]] && [(NSString *)legacy length] > 0) {
        if (ApolloWebJSONKeychainRead(kWebJSONKeychainAccountCookie).length == 0) {
            ApolloWebJSONKeychainWrite(kWebJSONKeychainAccountCookie, (NSString *)legacy);
        }
        // Only drop the world-readable defaults copy once the keychain actually
        // holds it — otherwise a failed keychain write would lose the credential.
        if (ApolloWebJSONKeychainRead(kWebJSONKeychainAccountCookie).length > 0) {
            [defaults removeObjectForKey:UDKeyWebSessionCookieHeader];
            ApolloLog(@"[WebJSON] Migrated legacy cookie header from NSUserDefaults to keychain");
        } else {
            ApolloLog(@"[WebJSON] Legacy cookie migration deferred — keychain write unavailable");
        }
    }

    sWebSessionCookieHeader = ApolloWebJSONKeychainRead(kWebJSONKeychainAccountCookie);
    sWebSessionModhash      = ApolloWebJSONKeychainRead(kWebJSONKeychainAccountModhash);
    sWebSessionUsername     = ApolloWebJSONKeychainRead(kWebJSONKeychainAccountUsername);
}

BOOL ApolloWebJSONHasUsableSession(void) {
    return sWebJSONEnabled && sWebSessionCookieHeader.length > 0;
}
