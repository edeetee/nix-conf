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
 * `text` is percent-encoded (with `"enc":"uri"` set) whenever it contains a newline,
 * a backslash or anything outside printable ASCII; otherwise it is sent verbatim.
 * Quotes are safe and are left alone — `cmux send` documents its escapes as `\n`, `\r`
 * and `\t` only, and a probe confirmed `\"` is typed through literally. A bare `\` is
 * still encoded because `\\n` in the JSON would re-form the `\n` escape. Multi-line
 * messages are therefore fine — see the first caveat for why unencoded ones are not.
 *
 * The receiving pi intercepts the envelope on the `input` event:
 *   - deliver:false (default) -> notification only; sender recorded for /reply
 *   - deliver:true           -> message routed to the receiving agent
 *
 * Caveats:
 *   - Delivery is LITERAL TYPING, and `cmux send` interprets backslash escapes. A
 *     payload with a raw newline in it is torn in two at that point: the first line is
 *     submitted alone, fails to parse as an envelope, and is never intercepted (it
 *     reaches the agent as ordinary user input, partial JSON and all), while every
 *     later line is typed as separate input and surfaces as a queue of `Steering:`
 *     fragments. JSON escaping does not save you, because the `\n` it writes is exactly
 *     what cmux unescapes. Hence the percent-encoding above.
 *   - Only send to surfaces actually running pi; otherwise the text lands in
 *     whatever shell is there.
 *   - If the target user is mid-edit, the envelope interleaves with the editor buffer;
 *     and if the target agent is mid-turn, the message is queued rather than read at
 *     once. Send while the target is idle.
 *   - Sender identity is self-reported: anything that can `cmux send` can
 *     spoof `from`. Fine on a single-user machine; treat received messages
 *     as untrusted input.
 *   - Envelope lookalikes (`{"pi-msg":...}`) are intercepted and consumed by
 *     design — they never reach the user or agent as plain text.
 */

const ENVELOPE_KEY = "pi-msg";
const MAX_ENVELOPE_BYTES = 64 * 1024;

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
  // "uri" when `text` is percent-encoded. Omitted for plain text, so single-line
  // messages stay byte-identical to what older receivers already expect.
  enc?: string;
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
function parseEnvelope(raw: string): Envelope | null {
  // The payload is typed into a terminal, so stray whitespace or a trailing CR is
  // expected and must not defeat recognition.
  const text = raw.trim();
  // Gate on the marker first (cheap, unambiguous), so the size cap can be high
  // without risking swallowing large user JSON that merely starts with "{".
  if (!text.startsWith(`{"${ENVELOPE_KEY}":`)) return null;
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

/**
 * Surviving the trip.
 *
 * The payload is not a pipe: `cmux send` *types* it into the target terminal and
 * interprets backslash escapes on the way. `JSON.stringify` writes a newline as the
 * two characters `\` `n`, cmux turns that back into a real newline, and the envelope
 * is then torn apart at that point - the first line is submitted on its own, fails to
 * parse as JSON, is never recognised as an envelope at all, and every later line is
 * typed as separate input (which the receiving agent, being mid-turn, sees as a queue
 * of `Steering:` fragments).
 *
 * So the payload must contain no backslash of its own and no literal newline. Anything
 * that would need one - newlines, tabs, non-ASCII, or a bare backslash (because `\\n`
 * would re-form the `\n` escape) - is percent-encoded, and the envelope records that
 * with `enc: "uri"`. Plain printable ASCII is sent verbatim, quotes included, which
 * keeps simple messages readable in logs and compatible with receivers that predate
 * this.
 */
const ENC_URI = "uri";
const needsEncoding = (text: string) => /[^\x20-\x7e]|\\/.test(text);

function encodeText(text: string): Pick<Envelope, "text" | "enc"> {
  if (!needsEncoding(text)) return { text };
  return { text: encodeURIComponent(text), enc: ENC_URI };
}

// A malformed percent sequence must not lose the message: fall back to the raw text.
function decodeText(env: Envelope): string {
  if (env.enc !== ENC_URI) return env.text;
  try {
    return decodeURIComponent(env.text);
  } catch {
    return env.text;
  }
}

function previewOf(text: string): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  return oneLine.length > 240 ? `${oneLine.slice(0, 240)}…` : oneLine;
}

/**
 * Text that was *meant* to be an envelope, even though it did not parse - torn at a
 * newline, escaped to death on the way in, or over the size cap. Deliberately laxer
 * than parseEnvelope: it is used to decide "damaged message" versus "prose", and both
 * mistakes are expensive. Swallowing prose loses a user's words; letting a damaged
 * envelope through dumps raw JSON into the agent's transcript, which is what this
 * guard exists to stop.
 */
function looksLikeEnvelope(text: string): boolean {
  return text.includes(`"${ENVELOPE_KEY}"`) && text.includes('"text"');
}

// The escapes JSON would have written, for fields recovered outside a real parse.
function unescapeJson(s: string): string {
  return s.replace(/\\(["\\/ntrbf])/g, (_, c: string) =>
    c === "n" ? "\n" : c === "t" ? "\t" : c === "r" ? "\r" : c === "b" ? "\b" : c === "f" ? "\f" : c,
  );
}

/**
 * Best-effort recovery from a damaged envelope, so a torn line still delivers its
 * message rather than inviting a resend. Handles both a complete `"text"` field and a
 * truncated one (everything from `"text":"` to the end of the input, minus any fields
 * that happened to follow it).
 */
function salvageEnvelope(text: string): Envelope | null {
  const complete = text.match(/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/);
  let body = complete?.[1];
  if (body === undefined) {
    const truncated = text.match(/"text"\s*:\s*"([\s\S]*)$/);
    if (!truncated?.[1]) return null;
    body = truncated[1].replace(/\","(?:enc|deliver|v|from)"[\s\S]*$/, "");
  }
  const encUri = /"enc"\s*:\s*"uri"/.test(text);
  const fromSurface = text.match(/"surface"\s*:\s*"([^"]+)"/)?.[1];
  const env: Envelope = {
    v: 1,
    text: encUri ? body : unescapeJson(body),
    deliver: /"deliver"\s*:\s*true/.test(text),
  };
  if (encUri) env.enc = ENC_URI;
  if (fromSurface) env.from = { surface: fromSurface };
  return env;
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
    if (text.length > MAX_ENVELOPE_BYTES) {
      return {
        ok: false,
        stdout: "",
        error: `message too long (${text.length} chars, max ${MAX_ENVELOPE_BYTES})`,
      };
    }
    const from = await ownIdentity();
    const env: Envelope = { v: 1, from, ...encodeText(text), deliver };
    const payload = formatEnvelope(env);
    // Encoding can triple the length, so the limit that matters is the encoded one:
    // it is the line the receiver has to read and parse.
    if (payload.length > MAX_ENVELOPE_BYTES) {
      return {
        ok: false,
        stdout: "",
        error: `message too long once encoded (${payload.length} chars, max ${MAX_ENVELOPE_BYTES})`,
      };
    }
    return runCmux(["send", "--surface", target, payload + "\n"]);
  };

  // ── receive: intercept envelopes submitted into this pi ──────────────
  pi.on("input", async (event, ctx) => {
    if (!inCmux) return; // never intercept outside cmux
    const env = parseEnvelope(event.text);

    // Damaged message, not prose. The old behaviour was to return nothing here, so a
    // torn or mangled envelope was passed through as ordinary input and arrived in the
    // agent's transcript as partial JSON - unreadable, and misleading about who said
    // what. Consume it instead: tell the human, and hand the agent whatever body could
    // be recovered, with a note that it is best-effort.
    if (!env) {
      if (!looksLikeEnvelope(event.text)) return;
      const recovered = salvageEnvelope(event.text);
      if (!recovered) {
        ctx.ui.notify(`cmux msg: undecodable envelope - ${previewOf(event.text)}`, "warning");
        return { action: "handled" };
      }
      const body = decodeText(recovered);
      const fromDesc = describeFrom(recovered.from);
      if (recovered.from) lastSender = recovered.from;
      if (recovered.deliver !== true) {
        ctx.ui.notify(`cmux msg from ${fromDesc} (damaged envelope): ${previewOf(body)}`, "warning");
        return { action: "handled" };
      }
      ctx.ui.notify(`cmux msg from ${fromDesc} (recovered from a damaged envelope)`, "warning");
      return {
        action: "transform",
        text: `[cmux msg from ${fromDesc} - the envelope was damaged in transit, so this body is best-effort] ${body}`,
      };
    }

    if (env.from) lastSender = env.from;
    const fromDesc = describeFrom(env.from);
    const body = decodeText(env);

    if (env.deliver === true) {
      // Hand the FULL text to the agent; the preview is only for the notification.
      ctx.ui.notify(`cmux msg from ${fromDesc}`, "info");
      return { action: "transform", text: `[cmux msg from ${fromDesc}] ${body}` };
    }
    ctx.ui.notify(`cmux msg from ${fromDesc}: ${previewOf(body)}`, "info");
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
