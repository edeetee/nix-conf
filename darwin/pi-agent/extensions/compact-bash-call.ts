/**
 * compact-bash-call - keep the bash tool row small when collapsed.
 *
 * Why: pi renders the tool *call* (the `$ <command>` header) verbatim and never
 * truncates it, so a command containing a heredoc script or a multi-line commit
 * message fills the screen even after ctrl+o collapses the output (which is
 * previewed at only ~5 lines anyway).
 *
 * What: overrides the built-in `bash` tool, delegating execution + result
 * rendering to the built-in implementation and only shortening renderCall.
 * Collapsed: first N lines, long lines clipped. Expanded (ctrl+o): full command.
 *
 * Remove this file (or /reload) to get the stock behavior back.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createBashTool } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";

const MAX_LINES = 4;
const MAX_LINE_CHARS = 160;

function clip(line: string): string {
	return line.length > MAX_LINE_CHARS ? `${line.slice(0, MAX_LINE_CHARS)}…` : line;
}

export default function (pi: ExtensionAPI) {
	const builtin = createBashTool(process.cwd()) as any;

	pi.registerTool({
		name: "bash",
		label: "bash",
		description: builtin.description,
		parameters: builtin.parameters,
		// Prompt metadata is not inherited by overrides, so pass it through.
		promptSnippet: builtin.promptSnippet,
		promptGuidelines: builtin.promptGuidelines,

		async execute(toolCallId, params, signal, onUpdate, ctx: any) {
			return createBashTool(ctx.cwd).execute(toolCallId, params as any, signal, onUpdate);
		},

		renderCall(args: any, theme: any, context: any) {
			const command = typeof args?.command === "string" ? args.command : "";
			const timeout = typeof args?.timeout === "number" ? args.timeout : undefined;
			const timeoutSuffix = timeout ? theme.fg("muted", ` (timeout ${timeout}s)`) : "";

			if (!command) {
				return new Text(theme.fg("toolTitle", theme.bold("$ ...")) + timeoutSuffix, 0, 0);
			}

			const lines = command.split("\n");
			const expanded = Boolean(context?.expanded);
			const shown = expanded ? lines : lines.slice(0, MAX_LINES).map(clip);
			let text = theme.fg("toolTitle", theme.bold(`$ ${shown.join("\n")}`));

			const hidden = lines.length - shown.length;
			if (hidden > 0) {
				text += theme.fg("muted", `\n… ${hidden} more line${hidden === 1 ? "" : "s"} (ctrl+o to show)`);
			}

			return new Text(text + timeoutSuffix, 0, 0);
		},

		// No renderResult -> the built-in bash result renderer is used as-is
		// (5-line collapsed preview, "... N earlier lines" hint, truncation notes).
	});
}
