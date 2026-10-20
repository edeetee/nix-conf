/**
 * budget — a spend cap for one user request, enforced from inside the loop.
 *
 * Why: a long tool loop on a growing context is where the money goes, and
 * instructions alone do not bound it. Measured A/B on a 4-file task (deepseek):
 * uncapped 62 s / $0.019, capped with in-context feedback 18 s / $0.0056, same
 * hidden-test score. The thing that changed behaviour was not the wall, it was
 * the model knowing the budget while it still had room to economise.
 *
 * What steers is the number, not the advice. There used to be a system-prompt
 * block of economy instructions ("read only the files you will change...") plus
 * an imperative tail on every tick. A/B on a 10-file task with the cap set at
 * the natural spend (9 runs per arm, deepseek-flash): $0.00214 / 5.7 turns with
 * the advice, $0.00231 / 5.7 turns with facts alone, both 9/9 on the hidden
 * check — a difference well inside the run-to-run spread. So the advice is now
 * opt-in (PI_BUDGET_GUIDANCE=full) and the default is just the numbers.
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
 * The same numbers are kept live in the footer status line (`budget 0.0060/0.1000 · 6%`),
 * updated on every turn and on every cap change, so the spend is visible while you type the
 * next prompt without spending a model request on it. It is dim below half the cap, warning
 * from half, error at the cap, and reads `no cap` when the limit is off.
 *
 * The limit defaults to $0.10 per user request and is inert only when explicitly
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
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

// $0.10, not $0.05: measured over 101 prompts (25 sessions, DeepSeek Flash) the p90
// prompt cost $0.099 and the mean $0.046, so a $0.05 cap interrupted ordinary work
// roughly one time in five. An aborted task is paid for twice — the context is re-sent
// when it is re-prompted — so the tight cap was itself a cost.
const DEFAULT_CAP_USD = 0.1;
const TICK_FRACTION = 0.1;
const ABORT_FRACTION = 1.3;
const SAVED_TYPE = "budget";
/** Footer status key; distinct from other extensions' keys (e.g. "auto-mode"). */
const STATUS_KEY = "budget";

/**
 * How much prose rides along with the numbers:
 *
 *   (default)                facts only: no system-prompt block, ticks state the
 *                            budget, percent used and requests left
 *   PI_BUDGET_GUIDANCE=full  also prepend `guidance` to the system prompt and
 *                            append an imperative to every tick (kept for A/B)
 */
const GUIDANCE = /^(full|on|1|true|yes)$/i.test((process.env.PI_BUDGET_GUIDANCE ?? "").trim());

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

/**
 * The status line: window spend against the cap, colored by how much of it is gone.
 * In interactive mode this rides on the footer's *stats* line (see `installFooter`), because
 * `ctx.ui.setStatus()` renders every status entry on a line of its own below the stats line.
 * RPC clients have no footer and do take `setStatus`, so there the number goes through that.
 */
function statusFor(spent: number, cap: number | null): { text: string; tone: string } {
	if (cap === null) return { text: `no cap · ${money(spent)}`, tone: "dim" };
	const fraction = spent / cap;
	return {
		text: `${money(spent)}/${money(cap)} · ${Math.round(fraction * 100)}%`,
		tone: fraction >= 1 ? "error" : fraction >= 0.5 ? "warning" : "dim",
	};
}

/** Token counts at the granularity the built-in footer uses. */
function tokenCount(count: number): string {
	if (count < 1000) return `${count}`;
	if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
	if (count < 1000000) return `${Math.round(count / 1000)}k`;
	if (count < 10000000) return `${(count / 1000000).toFixed(1)}M`;
	return `${Math.round(count / 1000000)}M`;
}

function shortCwd(cwd: string, home: string | undefined): string {
	if (!home || !cwd.startsWith(home)) return cwd;
	return `~${cwd.slice(home.length)}`;
}

/**
 * Session usage, accumulated the way the built-in footer does it: assistant and tool-result
 * messages, standalone usage entries, and compaction/branch-summary billing.
 */
function usageTotals(ctx: ExtensionContext): {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
	hitRate: number | undefined;
} {
	const totals = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, hitRate: undefined as number | undefined };
	for (const entry of ctx.sessionManager.getEntries() as any[]) {
		const usage =
			entry?.type === "usage"
				? entry.usage
				: entry?.type === "message"
					? entry.message?.usage
					: entry?.usage; // compaction / branch_summary
		if (!usage) continue;
		totals.input += usage.input ?? 0;
		totals.output += usage.output ?? 0;
		totals.cacheRead += usage.cacheRead ?? 0;
		totals.cacheWrite += usage.cacheWrite ?? 0;
		totals.cost += usage.cost?.total ?? 0;
		if (entry?.type === "message" && entry.message?.role === "assistant") {
			const promptTokens = (usage.input ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0);
			totals.hitRate = promptTokens > 0 ? ((usage.cacheRead ?? 0) / promptTokens) * 100 : undefined;
		}
	}
	return totals;
}

/** Left-aligned `left` and right-aligned `right` on one line, dropping the right side first. */
function twoColumns(left: string, right: string, width: number, ellipsis: string): string {
	const leftWidth = visibleWidth(left);
	const rightWidth = visibleWidth(right);
	if (leftWidth + 2 + rightWidth <= width) return left + " ".repeat(width - leftWidth - rightWidth) + right;
	const room = width - leftWidth - 2;
	if (room > 0) {
		const cut = truncateToWidth(right, room, "");
		return left + " ".repeat(Math.max(0, width - leftWidth - visibleWidth(cut))) + cut;
	}
	return truncateToWidth(left, width, ellipsis);
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
	/** What the footer's stats line appends; kept current by `updateStatus`. */
	let current = statusFor(0, cap);
	let requestRender: (() => void) | undefined;

	const resetWindow = (ctx: ExtensionContext) => {
		windowStart = spentUsd(ctx);
		windowTurns = 0;
		lastWindowSpend = 0;
		lastBucket = 0;
		stopRequested = false;
	};

	/** Spend in the current user request, which is what the cap applies to. */
	const windowSpend = (ctx: ExtensionContext) => Math.max(0, spentUsd(ctx) - windowStart);

	const updateStatus = (ctx: ExtensionContext, spent = windowSpend(ctx)) => {
		if (!ctx.hasUI) return;
		const status = statusFor(spent, cap);
		if (ctx.mode === "tui") {
			// The footer reads `status` on its next render, which we ask for here.
			current = status;
			requestRender?.();
			return;
		}
		let colored = status.text;
		try {
			const theme = (ctx.ui as { theme?: { fg?: (color: string, text: string) => string } }).theme;
			if (theme?.fg) colored = theme.fg(status.tone, status.text);
		} catch {
			// A theme without that token renders plain rather than breaking the footer.
		}
		ctx.ui.setStatus(STATUS_KEY, colored);
	};

	/**
	 * Replace the built-in footer with the same two lines, budget appended to the stats one.
	 * The alternative, `ctx.ui.setStatus()`, always renders below the stats line, i.e. a third
	 * footer line; a status on line two requires rendering the footer.
	 *
	 * Fidelity note: this mirrors the built-in footer's content (pwd · branch · session name,
	 * token totals, cache hit rate, cost, context %, model · thinking level), but it cannot see
	 * session runtime state that is not on `ctx`, so the built-in's `(auto)` compaction marker,
	 * `(sub)` subscription marker, routed-model arrow and `xp` badge are absent here.
	 */
	const installFooter = (ctx: ExtensionContext) => {
		ctx.ui.setStatus(STATUS_KEY, undefined);
		ctx.ui.setFooter((tui, theme, footerData) => {
			requestRender = () => tui.requestRender();
			let cachedKey = "";
			let totals = usageTotals(ctx);

			return {
				invalidate() {},
				dispose() {},
				render(width: number): string[] {
					const key = `${ctx.sessionManager.getLeafId() ?? ""}:${ctx.sessionManager.getEntries().length}`;
					if (key !== cachedKey) {
						cachedKey = key;
						totals = usageTotals(ctx);
					}

					const session = ctx.sessionManager;
					let pwd = shortCwd(session.getCwd(), process.env.HOME);
					const branch = footerData.getGitBranch();
					if (branch) pwd += ` (${branch})`;
					const name = session.getSessionName();
					if (name) pwd += ` • ${name}`;

					const usage = ctx.getContextUsage();
					const contextWindow = usage?.contextWindow ?? ctx.model?.contextWindow ?? 0;
					const percent = usage?.percent ?? 0;

					const parts: string[] = [];
					if (totals.input) parts.push(`↑${tokenCount(totals.input)}`);
					if (totals.output) parts.push(`↓${tokenCount(totals.output)}`);
					if (totals.cacheRead) parts.push(`R${tokenCount(totals.cacheRead)}`);
					if (totals.cacheWrite) parts.push(`W${tokenCount(totals.cacheWrite)}`);
					if ((totals.cacheRead || totals.cacheWrite) && totals.hitRate !== undefined) {
						parts.push(`CH${totals.hitRate.toFixed(1)}%`);
					}
					if (totals.cost) parts.push(`$${totals.cost.toFixed(3)}`);

					const contextText = `${percent.toFixed(1)}%/${tokenCount(contextWindow)}`;
					const contextColor = percent > 90 ? ("error" as const) : percent > 70 ? ("warning" as const) : ("dim" as const);

					const left = [
						...parts.map((part) => theme.fg("dim", part)),
						theme.fg(contextColor, contextText),
						theme.fg(current.tone, current.text),
					].join(" ");

					const model = ctx.model?.id ?? "no-model";
					const thinking = ctx.thinkingLevel ?? "off";
					const right = ctx.model?.reasoning ? `${model} • thinking ${thinking}` : model;

					const lines = [
						truncateToWidth(theme.fg("dim", pwd), width, theme.fg("dim", "...")),
						twoColumns(left, theme.fg("dim", right), width, theme.fg("dim", "...")),
					];

					// Other extensions' statuses keep their own line, as they had before.
					const others = Array.from(footerData.getExtensionStatuses().entries())
						.filter(([key]) => key !== STATUS_KEY)
						.map(([, text]) =>
							String(text)
								.replace(/[\r\n\t]/g, " ")
								.replace(/ +/g, " ")
								.trim(),
						);
					if (others.length) {
						lines.push(truncateToWidth(others.join(" "), width, theme.fg("dim", "...")));
					}
					return lines;
				},
			};
		});
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
		if (ctx.mode === "tui") installFooter(ctx);
		updateStatus(ctx, 0);
	});

	pi.on("before_agent_start", async (event, ctx) => {
		// A user prompt opens a new budget window.
		resetWindow(ctx);
		updateStatus(ctx, 0);
		if (cap === null || !GUIDANCE) return;
		return { systemPrompt: `${event.systemPrompt}\n\n${guidance(cap)}` };
	});

	pi.on("message_end", async (event, ctx) => {
		// A message typed while the agent is running is queued as a user message and
		// does not go through before_agent_start; it is still a new user request.
		if (event.message?.role === "user") {
			resetWindow(ctx);
			updateStatus(ctx, 0);
		}
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

		updateStatus(ctx, spent);

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
						content: GUIDANCE
							? `Budget ${describe(spent, cap)}; about ${requestsLeft} request(s) left at this ` +
								"burn rate. Make the smallest changes that satisfy the request; run the checks " +
								"once when you are done."
							: `Budget ${describe(spent, cap)}; about ${requestsLeft} request(s) left at this burn rate.`,
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
				updateStatus(ctx, 0);
				ctx.ui.notify("budget: no limit for this session", "info");
				return;
			}

			if (/^(on|default|reset)$/i.test(arg)) {
				cap = parseCap(undefined);
				pi.appendEntry(SAVED_TYPE, { cap });
				resetWindow(ctx);
				updateStatus(ctx, 0);
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
			updateStatus(ctx, 0);
			ctx.ui.notify(`budget: limit ${money(value)} per message, from your next prompt`, "info");
		},
	});
}
