/**
 * Worker entrypoint — wires the Hono router and the cron handler.
 */

import { buildRouter } from "./router.ts";
import { runPoll } from "./poll.ts";
import type { Env } from "./types.ts";
import type { ExecutionContext, ScheduledController } from "@cloudflare/workers-types";

const router = buildRouter();

export default {
    // router.fetch returns Response | Promise<Response> depending on the
    // matched handler; Workers accepts either.
    fetch(request: Request, env: Env, ctx: ExecutionContext): Response | Promise<Response> {
        return router.fetch(request, env, ctx);
    },

    async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
        // ctx.waitUntil lets the poll continue after this handler returns so
        // we don't have to keep the cron promise on the critical path.
        const promise = (async () => {
            const summary = await runPoll(env);
            console.log("[cron] summary:", JSON.stringify(summary));
        })().catch((err) => {
            console.error("[cron] failed:", err instanceof Error ? err.stack ?? err.message : String(err));
        });
        ctx.waitUntil(promise);
    },
};
