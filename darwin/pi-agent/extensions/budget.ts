/**
 * budget — a spend cap for one user request, enforced from inside the loop.
 *
 * Why: a long tool loop on a growing context is where the money goes, and
 * instructions alone do not bound it. Measured A/B on a 4-file task (deepseek):
 * uncapped 62 s / $0.019, capped with in-context feedback 18 s / $0.0056, same
 * hidden-test score. The thing that changed behaviour was not the wall, it was
 * the model knowing the budget while it still had room to economise.
 *
 * What: every user prompt opens a new window. Spend in that window is checked on
 * every turn end:
 *
 *   - every 10%  -> one custom message in context: percent used, dollars left,
 *                   and roughly how many requests that buys at this burn rate.
 *                   Only when the turn ended in a tool call, so it steers the
 *                   next request instead of adding one.
 *   - 100%       -> one message: finish the current edits, run the checks once,
 *                   report, stop.
 *   - 130%       -> abort.
 *
 * The limit defaults to $0.05 per user request and is inert only when explicitly
 * turned off. Resolution order:
 *
 *   PI_BUDGET_USD=0.25 pi ...   # per process, inherited by spawned agents
 *   PI_BUDGET_USD=off pi ...    # no limit for this process
 *   /budget 0.25                # this session, from the next prompt
 *   /budget off                 # this session, no limit
 *   /budget                     # report this message's spend
 *
 * The cap is per user message, not per session: sending a message resets it. A
 * `pi -p` sub-agent sees one user message, so its cap is its whole run — which is
 * why spawners should pass PI_BUDGET_USD sized to the task.
 *
 * Sending a prompt also resets the window, including a prompt queued while the
 * agent is running. Only the last 130% abort is destructive: the 100% message is
 * one more turn, so the agent can finish cleanly.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const DEFAULT_CAP_USD = 0.05;
const TICK_FRACTION = 0.1;
const ABORT_FRACTION = 1.3;
const SAVED_TYPE = "budget";

/** null = no limit. Undefined input means "use the built-in default". */
function parseCap(raw: string | undefined): number | null {
	if (raw === undefined) return DEFAULT_CAP_USD;
	const trimmed = raw.trim().toLowerCase();
	if (trimmed === "" || trimmed === "off" || trimmed === "none" || trimmed === "0") return null;
	const value = Number(trimmed.replace(/^\$/, ""));
	return Number.isFinite(value) && value > 0 ? value : DEFAULT_CAP_USD;
}

/** Total cost of this branch, from the assistant messages and usage entries in it. */
function spentUsd(ctx: ExtensionContext): number {
	let total = 0;
	for (const entry of ctx.sessionManager.getBranch() as any[]) {
		const cost = entry?.usage?.cost?.total ?? entry?.message?.usage?.cost?.total;
		if (typeof cost === "number" && Number.isFinite(cost)) total += cost;
	}
	return total;
}

function money(value: number): string {
	return `$${value.toFixed(4)}`;
}

function describe(spent: number, cap: number): string {
	return `${money(spent)} of ${money(cap)} (${Math.round((spent / cap) * 100)}%)`;
}

function guidance(cap: number): string {
	return [
		"## Spend budget",
		"",
		`This request is capped at ${money(cap)}. Every model request is charged, and cost grows with`,
		"the context, so extra reads and extra turns are what spend it.",
		"",
		"- Read the task and only the files you will change. Do not survey the repository.",
		"- Implement directly. No scratch scripts, extra docs, refactors or tests the task",
		"  does not ask for.",
		"- Run the checks when you believe you are done, fix what fails, stop.",
		"- Keep the final report short.",
	].join("\n");
}

export default function (pi: ExtensionAPI) {
	let cap = parseCap(process.env.PI_BUDGET_USD);

	/** Total branch spend when the current user request started. */
	let windowStart = 0;
	let windowTurns = 0;
	let lastWindowSpend = 0;
	let lastBucket = 0;
	let stopRequested = false;

	const resetWindow = (ctx: ExtensionContext) => {
		windowStart = spentUsd(ctx);
		windowTurns = 0;
		lastWindowSpend = 0;
		lastBucket = 0;
		stopRequested = false;
	};

	pi.on("session_start", async (_event, ctx) => {
		// A /budget choice saved in this session survives resume and fork.
		for (const entry of ctx.sessionManager.getBranch() as any[]) {
			if (entry?.type === "custom" && entry.customType === SAVED_TYPE) {
				const saved = entry.data?.cap;
				if (saved === null) cap = null;
				else if (typeof saved === "number" && saved > 0) cap = saved;
			}
		}
		resetWindow(ctx);
	});

	pi.on("before_agent_start", async (event, ctx) => {
		// A user prompt opens a new budget window.
		resetWindow(ctx);
		if (cap === null) return;
		return { systemPrompt: `${event.systemPrompt}\n\n${guidance(cap)}` };
	});

	pi.on("turn_end", async (event, ctx) => {
		if (cap === null) return;

		const spent = Math.max(0, spentUsd(ctx) - windowStart);
		windowTurns += 1;
		const perTurn = spent / windowTurns;
		const lastTurn = Math.max(0, spent - lastWindowSpend);
		lastWindowSpend = spent;
		const requestsLeft = Math.max(
			0,
			Math.round((cap - spent) / Math.max(lastTurn, perTurn, 1e-9)),
		);

		const continuing = (event.message?.content as any[] | undefined)?.some(
			(block) => block?.type === "toolCall",
		);

		if (spent >= cap * ABORT_FRACTION && stopRequested) {
			ctx.ui.notify(`budget: ${describe(spent, cap)} — over the cap, stopping`, "error");
			ctx.abort();
			return;
		}

		if (spent >= cap) {
			if (stopRequested) return;
			stopRequested = true;
			ctx.ui.notify(`budget: ${describe(spent, cap)} — asking the agent to stop`, "warning");
			return {
				continue: true,
				entries: [
					{
						type: "custom_message" as const,
						customType: SAVED_TYPE,
						display: true,
						content:
							`Budget ${describe(spent, cap)}. Do not start new work. Finish what is already ` +
							"edited, run the checks once, and report. Then stop.",
					},
				],
			};
		}

		const bucket = Math.floor((spent / cap) * (1 / TICK_FRACTION));
		if (continuing && bucket > lastBucket) {
			lastBucket = bucket;
			return {
				continue: true,
				entries: [
					{
						type: "custom_message" as const,
						customType: SAVED_TYPE,
						display: true,
						content:
							`Budget ${describe(spent, cap)}; about ${requestsLeft} request(s) left at this ` +
							"burn rate. Make the smallest changes that satisfy the request; run the checks " +
							"once when you are done.",
					},
				],
			};
		}
		lastBucket = Math.max(lastBucket, bucket);
	});

	pi.registerCommand("budget", {
		description: "Show or set this session's per-message spend cap (/budget 0.10, /budget off)",
		handler: async (args: string, ctx: ExtensionContext) => {
			const arg = args.trim();

			if (arg === "") {
				const spent = Math.max(0, spentUsd(ctx) - windowStart);
				const session = spentUsd(ctx);
				const suffix = session > spent + 0.00005 ? ` · ${money(session)} this session` : "";
				ctx.ui.notify(
					cap === null
						? `budget: ${money(spent)} on this message · no limit${suffix}`
						: `budget: ${describe(spent, cap)} on this message${suffix}`,
					"info",
				);
				return;
			}

			if (/^(off|none|no|disable)$/i.test(arg)) {
				cap = null;
				pi.appendEntry(SAVED_TYPE, { cap: null });
				resetWindow(ctx);
				ctx.ui.notify("budget: no limit for this session", "info");
				return;
			}

			if (/^(on|default|reset)$/i.test(arg)) {
				cap = parseCap(undefined);
				pi.appendEntry(SAVED_TYPE, { cap });
				resetWindow(ctx);
				ctx.ui.notify(`budget: default limit ${money(cap!)} per message`, "info");
				return;
			}

			const value = Number(arg.replace(/^\$/, ""));
			if (!Number.isFinite(value) || value <= 0) {
				ctx.ui.notify(
					`budget: "${arg}" is not an amount — try /budget 0.10, /budget off, /budget default`,
					"warning",
				);
				return;
			}

			cap = value;
			pi.appendEntry(SAVED_TYPE, { cap });
			resetWindow(ctx);
			ctx.ui.notify(`budget: limit ${money(value)} per message, from your next prompt`, "info");
		},
	});
}
