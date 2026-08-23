import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

/**
 * cmux-messaging — envelope-based messaging between pi sessions inside cmux.
 *
 * Any pi running in a cmux surface can send a structured message to any other
 * surface. Delivery is focus-independent (cmux routes input by surface ref,
 * verified empirically) and surface IDs (refs + UUIDs) are stable across
 * pane/workspace moves, so a sender stays addressable until its terminal
 * closes.
 *
 * Protocol — the sender runs:
 *   cmux send --surface <target> '{"pi-msg":{"v":1,"from":{...},"text":"...","deliver":false}}' + "\n"
 *
 * The receiving pi intercepts the envelope on the `input` event:
 *   - deliver:false (default) -> notification only; sender recorded for /reply
 *   - deliver:true           -> message routed to the receiving agent
 *
 * Caveats:
 *   - Only send to surfaces actually running pi; otherwise the text lands in
 *     whatever shell is there.
 *   - Delivery is like typing: if the target user is mid-edit, the envelope
 *     interleaves with the editor buffer. Send while the target is idle.
 */

const ENVELOPE_KEY = "pi-msg";
const MAX_ENVELOPE_BYTES = 4096;

type From = {
  surface?: string; // short ref, e.g. surface:64
  surfaceId?: string; // UUID
  workspace?: string; // short ref, e.g. workspace:44
  workspaceId?: string; // UUID
  window?: string; // short ref, e.g. window:1
};

type Envelope = {
  v?: number;
  from?: From;
  text: string;
  deliver?: boolean;
};

// Inside a cmux surface the app exports the bundled CLI path; the binary is
// also on PATH as cmux. Fall back to PATH resolution so we work even when the
// env candidates are absent (e.g. sockets opened from a non-cmux process).
function cmuxBinary(): string {
  const candidates = [
    process.env.CMUX_BUNDLED_CLI_PATH,
    "/opt/homebrew/bin/cmux",
    "/Applications/cmux.app/Contents/Resources/bin/cmux",
  ].filter((c): c is string => !!c && existsSync(c));
  return candidates[0] ?? "cmux";
}

function inCmuxSurface(): boolean {
  return Boolean(process.env.CMUX_WORKSPACE_ID);
}

function runCmux(args: string[]): Promise<{ ok: boolean; stdout: string; error?: string }> {
  return new Promise((resolve) => {
    execFile(cmuxBinary(), args, { timeout: 10_000 }, (err, stdout) => {
      if (err) resolve({ ok: false, stdout: "", error: String(err) });
      else resolve({ ok: true, stdout: String(stdout ?? "") });
    });
  });
}

// Own identity: prefer short refs from `cmux identify`, fall back to the env
// UUIDs every cmux-spawned process carries.
async function ownIdentity(): Promise<From> {
  const id: From = {};
  if (process.env.CMUX_SURFACE_ID) id.surfaceId = process.env.CMUX_SURFACE_ID;
  if (process.env.CMUX_WORKSPACE_ID) id.workspaceId = process.env.CMUX_WORKSPACE_ID;

  try {
    const r = await runCmux(["identify", "--json"]);
    if (!r.ok || !r.stdout) return id;
    const d = JSON.parse(r.stdout) as {
      caller?: { surface_ref?: string; workspace_ref?: string; window_ref?: string };
    };
    const c = d.caller;
    if (c) {
      if (c.surface_ref) id.surface = c.surface_ref;
      if (c.workspace_ref) id.workspace = c.workspace_ref;
      if (c.window_ref) id.window = c.window_ref;
    }
  } catch {
    // keep env-derived identity
  }
  return id;
}

// Only treat text as an envelope if it is compact JSON carrying a valid
// "pi-msg" object with a string `text`. Anything else passes through untouched.
function parseEnvelope(text: string): Envelope | null {
  if (!text.startsWith("{")) return null;
  if (text.length > MAX_ENVELOPE_BYTES) return null;
  try {
    const obj = JSON.parse(text) as Record<string, unknown>;
    const env = obj?.[ENVELOPE_KEY];
    if (!env || typeof env !== "object") return null;
    const e = env as Partial<Envelope>;
    if (typeof e.text !== "string") return null;
    return e as Envelope;
  } catch {
    return null;
  }
}

function formatEnvelope(env: Envelope): string {
  return JSON.stringify({ [ENVELOPE_KEY]: env });
}

function describeFrom(f: From | undefined): string {
  if (!f) return "unknown sender";
  const parts: string[] = [];
  if (f.surface) parts.push(f.surface);
  else if (f.surfaceId) parts.push(`${f.surfaceId.slice(0, 8)}…`);
  if (f.workspace) parts.push(`ws ${f.workspace}`);
  else if (f.workspaceId) parts.push(`ws ${f.workspaceId.slice(0, 8)}…`);
  return parts.join(" ") || "unknown sender";
}

export default function (pi: ExtensionAPI) {
  const inCmux = inCmuxSurface();
  let lastSender: From | null = null;

  const sendTo = async (target: string, text: string, deliver: boolean) => {
    const from = await ownIdentity();
    const env: Envelope = { v: 1, from, text, deliver };
    return runCmux(["send", "--surface", target, formatEnvelope(env) + "\n"]);
  };

  // ── receive: intercept envelopes submitted into this pi ──────────────
  pi.on("input", async (event, ctx) => {
    if (!inCmux) return; // never intercept outside cmux
    const env = parseEnvelope(event.text);
    if (!env) return;

    if (env.from) lastSender = env.from;
    const fromDesc = describeFrom(env.from);
    const preview = env.text.length > 240 ? `${env.text.slice(0, 240)}…` : env.text;

    if (env.deliver === true) {
      // Hand to the agent as a readable message.
      ctx.ui.notify(`cmux msg from ${fromDesc}`, "info");
      return { action: "transform", text: `[cmux msg from ${fromDesc}] ${preview}` };
    }
    ctx.ui.notify(`cmux msg from ${fromDesc}: ${preview}`, "info");
    return { action: "handled" };
  });

  // ── send: commands ──────────────────────────────────────────────────
  pi.registerCommand("msg", {
    description: "Send a cmux message to another pi (usage: /msg <surface-ref|uuid> <text>)",
    handler: async (args, ctx) => {
      if (!inCmux) {
        ctx.ui.notify("Not inside a cmux surface", "error");
        return;
      }
      const m = args.match(/^(\S+)\s+([\s\S]+)$/);
      if (!m) {
        ctx.ui.notify("Usage: /msg <target-surface> <text>", "error");
        return;
      }
      const target = m[1]!;
      const text = m[2]!;
      const r = await sendTo(target, text, false);
      ctx.ui.notify(r.ok ? `Sent to ${target}` : `Send failed: ${r.error}`, r.ok ? "info" : "error");
    },
  });

  pi.registerCommand("reply", {
    description: "Reply to the last cmux message sender (usage: /reply <text>)",
    handler: async (args, ctx) => {
      if (!inCmux) {
        ctx.ui.notify("Not inside a cmux surface", "error");
        return;
      }
      const text = args.trim();
      if (!text) {
        ctx.ui.notify("Usage: /reply <text>", "error");
        return;
      }
      const target = lastSender?.surface || lastSender?.surfaceId;
      if (!target) {
        ctx.ui.notify("No cmux sender recorded yet", "error");
        return;
      }
      const r = await sendTo(target, text, false);
      ctx.ui.notify(
        r.ok ? `Replied to ${describeFrom(lastSender)}` : `Reply failed: ${r.error}`,
        r.ok ? "info" : "error",
      );
    },
  });

  // ── send: LLM tools ─────────────────────────────────────────────────
  pi.registerTool({
    name: "cmux_msg",
    label: "Send cmux message",
    description:
      "Send a message to another pi instance running in a cmux surface. " +
      "With deliver=true the receiving agent processes it; otherwise the target user sees a notification. " +
      "Target is a cmux surface ref (surface:N) or UUID — enumerate targets with the cmux CLI (cmux tree, cmux list-pane-surfaces). " +
      "Your own identity is attached automatically, so the recipient can reply to you.",
    parameters: Type.Object({
      target: Type.String({ description: "Target cmux surface ref (surface:N) or UUID" }),
      text: Type.String({ description: "Message text" }),
      deliver: Type.Optional(Type.Boolean({ description: "Deliver to the receiving agent (default false)" })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (!inCmux) {
        return {
          content: [{ type: "text", text: "Not running inside a cmux surface; nothing sent." }],
          details: {},
        };
      }
      const r = await sendTo(params.target, params.text, params.deliver === true);
      if (r.ok) {
        return { content: [{ type: "text", text: `Sent to ${params.target}.` }], details: {} };
      }
      return {
        content: [
          { type: "text", text: `Failed to send to ${params.target}: ${r.error ?? "unknown error"}` },
        ],
        details: { isError: true },
      };
    },
  });

  pi.registerTool({
    name: "cmux_whoami",
    label: "cmux identity",
    description: "Report this pi instance's cmux identity (surface/workspace refs and UUIDs).",
    parameters: Type.Object({}),
    async execute() {
      if (!inCmux) {
        return {
          content: [{ type: "text", text: "Not running inside a cmux surface." }],
          details: {},
        };
      }
      const id = await ownIdentity();
      return { content: [{ type: "text", text: JSON.stringify(id, null, 2) }], details: {} };
    },
  });
}
