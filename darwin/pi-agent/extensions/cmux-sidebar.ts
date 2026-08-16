import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

/**
 * cmux-sidebar — keep the cmux sidebar title + description in sync with
 * the current pi session, deterministically (no LLM calls).
 *
 * - Title     <- pi session name (synced on /name and on session load/resume)
 * - Description <- the latest substantive user message (synced when the
 *                  agent settles)
 * - Explicit control via the `update_cmux_sidebar` tool.
 *
 * No-ops unless pi is running inside a cmux surface (CMUX_WORKSPACE_ID set).
 */

// Inside a cmux surface the app exports the bundled CLI path; after bundling
// via nix/homebrew the binary is also on PATH as /opt/homebrew/bin/cmux.
function cmuxBinary(): string | null {
  const candidates = [
    process.env.CMUX_BUNDLED_CLI_PATH,
    "/opt/homebrew/bin/cmux",
    "/Applications/cmux.app/Contents/Resources/bin/cmux",
  ];
  for (const c of candidates) {
    if (c && existsSync(c)) return c;
  }
  return null;
}

function inCmuxSurface(): boolean {
  return Boolean(process.env.CMUX_WORKSPACE_ID);
}

function runCmux(args: string[]): Promise<{ ok: boolean; error?: string }> {
  const bin = cmuxBinary();
  if (!bin) return Promise.resolve({ ok: false, error: "cmux CLI not found" });
  return new Promise((resolve) => {
    execFile(bin, args, { timeout: 10_000 }, (err) => {
      resolve(err ? { ok: false, error: String(err) } : { ok: true });
    });
  });
}

// ── deterministic description derivation ────────────────────────────────

type Block = { type?: string; text?: string };
type Entry = { type?: string; message?: { role?: string; content?: unknown } };

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter(
      (b): b is Block =>
        !!b &&
        typeof b === "object" &&
        (b as Block).type === "text" &&
        typeof (b as Block).text === "string",
    )
    .map((b) => (b as Block).text as string)
    .join(" ");
}

function userTasks(entries: Entry[]): string[] {
  const out: string[] = [];
  for (const e of entries) {
    if (e?.type === "message" && e.message?.role === "user") {
      const t = textOf(e.message.content).replace(/\s+/g, " ").trim();
      if (t) out.push(t);
    }
  }
  return out;
}

// Prefer the latest substantive user message (current focus); fall back to
// the session's opening task so short follow-ups like "yes" don't win.
function pickTask(entries: Entry[]): string {
  const tasks = userTasks(entries);
  if (tasks.length === 0) return "";
  for (let i = tasks.length - 1; i >= 0; i--) {
    if (tasks[i].length >= 20) return tasks[i];
  }
  return tasks[0];
}

// The longest user message is usually the main task statement.
function longestTask(entries: Entry[]): string {
  const tasks = userTasks(entries);
  if (tasks.length === 0) return "";
  let best = tasks[0];
  for (const t of tasks) if (t.length > best.length) best = t;
  return best;
}

// Title prefers an explicit session name, else the main task.
function pickTitle(entries: Entry[], sessionName?: string): string {
  const name = sessionName?.trim();
  if (name) return name;
  return truncate(longestTask(entries), 70);
}

function truncate(s: string, n: number): string {
  return s.length > n ? s.slice(0, n - 1).trimEnd() + "…" : s;
}

export default function (pi: ExtensionAPI) {
  // Title: sync pi's session name to the workspace name.
  pi.on("session_info_changed", async (event) => {
    if (!inCmuxSurface()) return;
    const name = event.name?.trim();
    if (name) await runCmux(["rename-workspace", name]);
  });

  // Re-apply the title when a session is loaded/resumed/reloaded.
  pi.on("session_start", async (_event, ctx) => {
    if (!inCmuxSurface()) return;
    try {
      const title = pickTitle(ctx.sessionManager.getBranch(), pi.getSessionName());
      if (title) await runCmux(["rename-workspace", title]);
    } catch {
      // Never break the agent over a cosmetic sidebar update.
    }
  });

  // Refresh title + description once the agent settles.
  pi.on("agent_settled", async (_event, ctx) => {
    if (!inCmuxSurface()) return;
    try {
      const entries = ctx.sessionManager.getBranch();
      const title = pickTitle(entries, pi.getSessionName());
      const description = truncate(pickTask(entries), 140);
      if (title) await runCmux(["rename-workspace", title]);
      if (description) {
        await runCmux(["workspace-action", "--action", "set-description", "--description", description]);
      }
    } catch {
      // Never break the agent over a cosmetic sidebar update.
    }
  });

  // Explicit control surface for the model.
  pi.registerTool({
    name: "update_cmux_sidebar",
    label: "Update cmux sidebar",
    description:
      "Set the cmux workspace sidebar title and/or description for the current workspace. " +
      "Call to label or re-label the workspace; omit a field to leave it unchanged.",
    parameters: Type.Object({
      title: Type.Optional(Type.String({ description: "Sidebar title (workspace name)" })),
      description: Type.Optional(Type.String({ description: "Sidebar description" })),
    }),
    async execute(_toolCallId, params) {
      if (!inCmuxSurface()) {
        return {
          content: [
            { type: "text", text: "Not running inside a cmux surface; sidebar update skipped." },
          ],
          details: {},
        };
      }

      const jobs: Promise<{ ok: boolean; error?: string }>[] = [];
      if (params.title?.trim()) jobs.push(runCmux(["rename-workspace", params.title.trim()]));
      if (params.description?.trim())
        jobs.push(
          runCmux(["workspace-action", "--action", "set-description", "--description", params.description.trim()]),
        );

      if (jobs.length === 0) {
        return {
          content: [{ type: "text", text: "Nothing to update: provide a title and/or description." }],
          details: {},
        };
      }

      const results = await Promise.all(jobs);
      const failed = results.filter((r) => !r.ok);
      if (failed.length) {
        return {
          content: [
            {
              type: "text",
              text: `cmux sidebar update failed: ${failed.map((f) => f.error).join("; ")}`,
            },
          ],
          details: {},
        };
      }
      return { content: [{ type: "text", text: "cmux sidebar updated." }], details: {} };
    },
  });
}
