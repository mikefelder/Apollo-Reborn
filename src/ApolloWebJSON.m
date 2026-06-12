#import "ApolloWebJSON.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "Defaults.h"

// Spike whitelist: subreddit listings and the front page only. Narrow on
// purpose — every other Reddit call continues through the oauth path so a
// half-working escape hatch can't silently degrade the rest of the app.
//
// Matches (with or without a trailing ".json" / "/"):
//   /                      front page
//   /hot /new /top /rising /best /controversial
//   /r/<sub>
//   /r/<sub>/(hot|new|top|rising|best|controversial)
static BOOL ApolloWebJSONPathIsWhitelisted(NSString *path) {
    if (path.length == 0) return NO;

    // Normalize: strip one trailing ".json" and any trailing "/".
    NSString *p = path;
    if ([p hasSuffix:@".json"]) p = [p substringToIndex:p.length - 5];
    while ([p hasSuffix:@"/"] && p.length > 1) p = [p substringToIndex:p.length - 1];

    static NSSet<NSString *> *sorts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sorts = [NSSet setWithArray:@[@"hot", @"new", @"top", @"rising", @"best", @"controversial"]];
    });

    // Front page: "/" or "/<sort>".
    if ([p isEqualToString:@"/"]) return YES;
    if (p.length > 1 && [p characterAtIndex:0] == '/' && [sorts containsObject:[p substringFromIndex:1]]) return YES;

    // Subreddit listing: "/r/<sub>" or "/r/<sub>/<sort>".
    if (![p hasPrefix:@"/r/"]) return NO;
    NSArray<NSString *> *parts = [[p substringFromIndex:3] componentsSeparatedByString:@"/"];
    if (parts.count == 1) return parts[0].length > 0;
    if (parts.count == 2) return parts[0].length > 0 && [sorts containsObject:parts[1]];
    return NO;
}

NSURLRequest *ApolloWebJSONRewriteRequest(NSURLRequest *request) {
    if (!sWebJSONEnabled || !request) return nil;

    NSURL *url = request.URL;
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"oauth.reddit.com"] && ![host isEqualToString:@"www.reddit.com"]) return nil;

    // Listings are GETs; anything else is out of the spike's scope.
    NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
    if (![method isEqualToString:@"GET"]) return nil;

    if (!ApolloWebJSONPathIsWhitelisted(url.path)) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return nil;
    components.host = @"www.reddit.com";

    // Reddit's web listing convention: the path must carry ".json".
    NSString *path = components.path ?: @"/";
    if (![path hasSuffix:@".json"]) {
        while ([path hasSuffix:@"/"] && path.length > 1) path = [path substringToIndex:path.length - 1];
        components.path = [path isEqualToString:@"/"] ? @"/.json" : [path stringByAppendingString:@".json"];
    }

    NSURL *rewrittenURL = components.URL;
    if (!rewrittenURL) return nil;

    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = rewrittenURL;

    // Cookie auth replaces the bearer token outright.
    [mutable setValue:nil forHTTPHeaderField:@"Authorization"];
    if (sWebSessionCookieHeader.length > 0) {
        // Set the header explicitly rather than relying on a cookie jar —
        // RDKClient's AFHTTPSessionManager session config may use a non-shared
        // jar, and HTTPShouldHandleCookies=NO stops the session from
        // overriding our header with (or storing) jar cookies.
        [mutable setValue:sWebSessionCookieHeader forHTTPHeaderField:@"Cookie"];
        mutable.HTTPShouldHandleCookies = NO;
    }

    [mutable setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];

    ApolloLog(@"[WebJSON] Rewrote %@ %@ -> %@ (cookie %@)",
              method, url.absoluteString, rewrittenURL.absoluteString,
              sWebSessionCookieHeader.length > 0 ? @"attached" : @"absent");
    return mutable;
}

void ApolloWebJSONSetSessionCookieHeader(NSString *cookieHeader) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (cookieHeader.length > 0) {
        sWebSessionCookieHeader = [cookieHeader copy];
        [defaults setObject:sWebSessionCookieHeader forKey:UDKeyWebSessionCookieHeader];
    } else {
        sWebSessionCookieHeader = nil;
        [defaults removeObjectForKey:UDKeyWebSessionCookieHeader];
    }
}
