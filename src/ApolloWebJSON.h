#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Web JSON spike — OAuth-free escape hatch (flag-gated, dormant by default).
//
// Reddit has closed self-service OAuth app registration, so a future API-key
// revocation wave would leave no path to new keys. The proven recovery model
// (Hydra's) is to drive www.reddit.com/...json with a WebView-harvested
// session cookie instead of oauth.reddit.com + bearer tokens. This module is
// the transport half of that: a routing helper spliced into the
// __NSCFLocalSessionTask chokepoint (Tweak.xm) that re-points a narrow
// whitelist of listing reads at www.reddit.com.
//
// Scope: subreddit/front-page listings only. Write actions (modhash),
// per-endpoint transforms, and AccountManager identity integration are
// deliberately out of scope — see docs/web-json-spike-findings.md.

// Returns a rewritten copy of `request` re-pointed at www.reddit.com/...json
// with the Authorization header stripped and the harvested session cookie
// attached, or nil when the feature flag is off, the request isn't a Reddit
// API call, or the path isn't in the spike's listing whitelist (caller then
// proceeds with the normal oauth path).
NSURLRequest *ApolloWebJSONRewriteRequest(NSURLRequest *request);

// Updates sWebSessionCookieHeader and persists it (nil/empty clears). Called
// by ApolloWebSessionLoginViewController after harvesting cookies.
void ApolloWebJSONSetSessionCookieHeader(NSString *cookieHeader);

#ifdef __cplusplus
}
#endif
