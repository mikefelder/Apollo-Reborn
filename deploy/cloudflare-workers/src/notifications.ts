/**
 * APNs payload builders for inbox notifications.
 *
 * These mirror the categories and custom-field keys that Apollo's notification
 * service extension and UN action handlers expect (read off
 * apollo-backend/internal/api/notifications.go and devices.go).
 *
 * Apollo's NSE inspects the `aps.category` to pick which iOS notification
 * category to use (controls action buttons), and pulls authoring metadata
 * (post_id, comment_id, subreddit, etc.) out of the custom keys.
 */

import type { ApnsPayload } from "./apns.ts";
import type { RedditThing } from "./types.ts";

const SOUND = "traloop.wav";

/**
 * Strips the `t1_` / `t3_` etc. type prefix off a Reddit fullname.
 * Returns the original if no prefix matches.
 */
function stripPrefix(fullname: string | undefined): string {
    if (!fullname) return "";
    const m = fullname.match(/^t[1-6]_(.+)$/);
    return m ? (m[1] as string) : fullname;
}

/**
 * Builds the APNs payload for a single Reddit inbox item.
 *
 * `accountId` is the recipient account's Reddit ID (the one that owns the
 * inbox) so Apollo can switch context correctly when the user taps.
 *
 * Returns null if the thing doesn't map to a category Apollo handles (skips
 * mod messages and similar without crashing).
 */
export function buildInboxPayload(
    thing: RedditThing,
    accountId: string,
    destinationAuthor: string,
): ApnsPayload | null {
    const d = thing.data;
    const isComment = thing.kind === "t1";
    const type = d.type;

    let category: string;
    let title: string;
    let subtitle: string | undefined;
    let body: string;
    let threadId: string;
    let custom: Record<string, unknown>;

    if (isComment && type === "username_mention") {
        category = "inbox-username-mention-no-context";
        title = `Mention in "${d.link_title ?? d.subject ?? ""}"`;
        body = d.body ?? "";
        threadId = "comment";
        custom = {
            account_id: accountId,
            author: d.author ?? "",
            comment_id: d.id,
            destination_author: destinationAuthor,
            parent_id: d.parent_id ?? "",
            post_id: stripPrefix(d.link_id),
            post_title: d.link_title ?? "",
            subject: "comment",
            subreddit: d.subreddit ?? "",
            type: "username",
        };
    } else if (isComment && (type === "comment_reply" || type === "post_reply")) {
        const isPost = type === "post_reply";
        category = "inbox-comment-reply";
        const verb = isPost ? "to" : "in";
        title = `${d.author ?? ""} ${verb} ${d.link_title ?? ""}`;
        body = d.body ?? "";
        threadId = "comment";
        custom = {
            account_id: accountId,
            author: d.author ?? "",
            comment_id: d.id,
            destination_author: destinationAuthor,
            parent_id: d.parent_id ?? "",
            post_id: stripPrefix(d.link_id),
            post_title: d.link_title ?? "",
            subject: "comment",
            subreddit: d.subreddit ?? "",
            type: isPost ? "post" : "comment",
        };
    } else if (thing.kind === "t4") {
        category = "inbox-private-message";
        title = `Message from ${d.author ?? "unknown"}`;
        subtitle = d.subject ?? undefined;
        body = d.body ?? "";
        threadId = `pm-${d.author ?? "unknown"}`;
        custom = {
            account_id: accountId,
            author: d.author ?? "",
            comment_id: d.id,
            destination_author: destinationAuthor,
            parent_id: d.parent_id ?? "",
            post_title: "",
            subreddit: "",
            type: "private-message",
        };
    } else {
        // Unknown kind (mod mail, etc.). Skip rather than crash; the message
        // still gets recorded as seen so we don't keep retrying it.
        return null;
    }

    return {
        aps: {
            alert: { title, subtitle, body },
            sound: SOUND,
            category,
            "mutable-content": 1,
            "thread-id": threadId,
        },
        ...custom,
    };
}

/**
 * Test-push payload triggered by POST /v1/device/{apns}/test. Mirrors the
 * format the Go backend emits — Apollo's NSE handles it via the
 * "test-notification" category.
 */
export function buildTestPayload(usernames: string[]): ApnsPayload {
    const list =
        usernames.length === 0
            ? "no accounts yet"
            : usernames.length === 1
                ? usernames[0]!
                : usernames.slice(0, -1).join(", ") + " and " + usernames[usernames.length - 1];
    return {
        aps: {
            alert: {
                title: "📣 Hello, is this thing on?",
                body: `Active usernames are: ${list}. Tap me for more info!`,
            },
            sound: SOUND,
            category: "test-notification",
            "mutable-content": 1,
        },
        test_accounts: usernames.join(","),
    };
}
