import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { basename } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

/**
 * cmux-sidebar — keep the cmux sidebar in sync with the pi session, deterministically
 * (no LLM calls).
 *
 * Each sidebar field has exactly one job:
 *
 *   - Workspace title = identity. MONOTONE: the base label (repo/dir name) sits at
 *     index 0 and labels are only ever appended. Nothing is removed, reordered or
 *     truncated to make room, so a workspace named after a repo or a set of features
 *     never narrows down to whichever single feature was touched last.
 *   - Tab title = what this surface is doing. Named once, on the first meaningful
 *     request, then left alone (`update_cmux_sidebar` can rename it explicitly).
 *   - Description = what is open in the workspace right now: its tabs, plus an
 *     optional note the agent sets. Rewritten only when the rendering changes.
 *   - Status pills / progress = transient run state, owned by cmux's own pi hook.
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

type CmuxResult = { ok: boolean; stdout: string; error?: string };

// cmux 0.64.22 exports CMUX_TAB_ID equal to the workspace UUID, so any command that
// resolves "the caller's tab" from it fails with `not_found: Tab not found` (that is
// what silently kept every pi tab on cmux's own "π - <dir>" auto title). Pass
// `--surface "$CMUX_SURFACE_ID"` explicitly, and drop the bogus variable from the
// child env so caller inference cannot pick it up.
function childEnv(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  if (env.CMUX_TAB_ID && env.CMUX_TAB_ID === env.CMUX_WORKSPACE_ID) delete env.CMUX_TAB_ID;
  return env;
}

function runCmux(args: string[]): Promise<CmuxResult> {
  const bin = cmuxBinary();
  if (!bin) return Promise.resolve({ ok: false, stdout: "", error: "cmux CLI not found" });
  return new Promise((resolve) => {
    execFile(bin, args, { timeout: 10_000, maxBuffer: 4 * 1024 * 1024, env: childEnv() }, (err, stdout) => {
      if (err) {
        resolve({ ok: false, stdout: stdout ?? "", error: (err as Error).message });
        return;
      }
      resolve({ ok: true, stdout: stdout ?? "" });
    });
  });
}

// ── reading cmux state ──────────────────────────────────────────────────

type WorkspaceInfo = {
  id?: string;
  ref?: string;
  title?: string;
  custom_title?: string | null;
  has_custom_title?: boolean;
  description?: string | null;
  current_directory?: string;
  selected?: boolean;
};

type Tab = { ref?: string; title?: string; selected?: boolean; surface_type?: string };

async function readWorkspace(): Promise<WorkspaceInfo | null> {
  const result = await runCmux(["workspace", "list", "--json"]);
  if (!result.ok) return null;
  try {
    const parsed = JSON.parse(result.stdout) as { workspaces?: WorkspaceInfo[] };
    const list = parsed.workspaces ?? [];
    const id = process.env.CMUX_WORKSPACE_ID;
    return list.find((w) => w.id === id) ?? list.find((w) => w.selected) ?? list[0] ?? null;
  } catch {
    return null;
  }
}

async function readTabs(wsRef?: string): Promise<{ tabs: Tab[]; currentRef?: string }> {
  const args = ["tree", "--json"];
  if (wsRef) args.push("--workspace", wsRef);
  const result = await runCmux(args);
  if (!result.ok) return { tabs: [] };
  try {
    const parsed = JSON.parse(result.stdout) as {
      caller?: { surface_ref?: string };
      windows?: { workspaces?: { ref?: string; panes?: { surfaces?: Tab[] }[] }[] }[];
    };
    const tabs: Tab[] = [];
    for (const win of parsed.windows ?? []) {
      for (const ws of win.workspaces ?? []) {
        if (wsRef && ws.ref && ws.ref !== wsRef) continue;
        for (const pane of ws.panes ?? []) tabs.push(...(pane.surfaces ?? []));
      }
    }
    return { tabs, currentRef: parsed.caller?.surface_ref };
  } catch {
    return { tabs: [] };
  }
}

// ── title model: base + append-only labels ──────────────────────────────

const TITLE_SEP = " · ";
const MAX_LABELS = 3;
const MAX_LABEL_CHARS = 28;
const MAX_DESCRIPTION_CHARS = 160;
const MAX_TABS_SHOWN = 4;
const MIN_PROMPT_CHARS = 40;

type TitleModel = { base: string; labels: string[] };

function truncate(s: string, n: number): string {
  return s.length > n ? s.slice(0, n - 1).trimEnd() + "…" : s;
}

function cleanLabel(raw: string): string {
  let label = raw.replace(/[\r\n\t]+/g, " ").replace(/\s+/g, " ").trim();
  label = label.replace(/^[-*•\d.)\s]+/, "").replace(/^["'`]+|["'`]+$/g, "").trim();
  label = label.replace(/[.;:,!?]+$/, "").trim();
  if (label.length > MAX_LABEL_CHARS) {
    const cut = label.slice(0, MAX_LABEL_CHARS);
    const atWord = cut.lastIndexOf(" ");
    label = (atWord > 12 ? cut.slice(0, atWord) : cut).trim();
  }
  return label;
}

function parseTitle(raw: string | null | undefined): TitleModel {
  const text = (raw ?? "").trim();
  if (!text) return { base: "", labels: [] };
  const at = text.indexOf(TITLE_SEP);
  if (at < 0) return { base: text, labels: [] };
  const labels = text
    .slice(at + TITLE_SEP.length)
    .split(",")
    .map(cleanLabel)
    .filter(Boolean);
  return { base: text.slice(0, at).trim(), labels };
}

function renderTitle(model: TitleModel): string {
  return model.labels.length ? `${model.base}${TITLE_SEP}${model.labels.join(", ")}` : model.base;
}

/**
 * Union `incoming` labels into `model`. Never removes, never reorders, and never drops a
 * label to fit an incoming one: when the set is full the incoming label is reported as
 * skipped instead. A label counts as covered when it is a case-insensitive match of, or
 * a substring of, a label already present.
 */
function widenTitle(
  model: TitleModel,
  incoming: string[],
): { model: TitleModel; added: string[]; skipped: string[] } {
  const labels = [...model.labels];
  const added: string[] = [];
  const skipped: string[] = [];
  const base = model.base.trim().toLowerCase();
  for (const raw of incoming) {
    const label = cleanLabel(raw);
    if (!label) continue;
    const low = label.toLowerCase();
    const covered =
      labels.some((existing) => {
        const e = existing.toLowerCase();
        return e === low || e.includes(low) || low.includes(e);
      }) ||
      // The base label already covers it (`nix-conf` vs "nix"), so never re-add it.
      (base.length > 0 && low.length >= 3 && (base === low || base.includes(low) || low.includes(base)));
    if (covered || labels.length >= MAX_LABELS) {
      skipped.push(label);
      continue;
    }
    labels.push(label);
    added.push(label);
  }
  return { model: { base: model.base, labels }, added, skipped };
}

// ── tab naming + description rendering ──────────────────────────────────

const STOPWORDS = new Set(
  (
    "the a an and or but to for of in on with is are be been being can could should would " +
    "you your we i it its this that these those please just make get add fix how what why " +
    "does do did when where which use using some our my me us if then than so not no yes ok " +
    "okay also now need want like let lets have has had was were will from at by as into " +
    "about over up down out only maybe really still again there here they them he she his her " +
    "them very much more most such own same then thus"
  ).split(/\s+/),
);

/** A short, stable tab name from the first meaningful request. */
function deriveTabLabel(prompt: string): string {
  const text = prompt
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`[^`]*`/g, " ")
    .replace(/https?:\/\/\S+/g, " ")
    .replace(/[^\p{L}\p{N}\s._/-]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
  const words = text.split(" ").filter((w) => w.length >= 3 && !STOPWORDS.has(w.toLowerCase()));
  const picked: string[] = [];
  for (const word of words) {
    if (picked.some((p) => p.toLowerCase() === word.toLowerCase())) continue;
    picked.push(word);
    if (picked.join(" ").length >= 30 || picked.length >= 4) break;
  }
  return cleanLabel(picked.join(" "));
}

function tabLabel(title: string | undefined): string {
  const raw = (title ?? "").trim();
  if (!raw) return "terminal";
  // Auto titles are "<glyph> - <cwd basename>" (e.g. "π - nix-conf").
  return raw.replace(/^(.{1,3})\s+-\s+/u, "").trim() || raw;
}

function renderDescription(tabs: Tab[], currentRef: string | undefined, note: string): string {
  const names: string[] = [];
  for (const tab of tabs) {
    const label =
      tab.ref && currentRef && tab.ref === currentRef ? `${tabLabel(tab.title)} (this)` : tabLabel(tab.title);
    if (!names.includes(label)) names.push(label);
  }

  const parts: string[] = [];
  let dropped = 0;
  for (let i = 0; i < names.length; i += 1) {
    const remaining = names.length - i - 1;
    const candidate = [...parts, names[i]].join(TITLE_SEP);
    const suffix = remaining > 0 ? ` +${remaining} more` : "";
    if (i >= MAX_TABS_SHOWN || candidate.length + suffix.length > MAX_DESCRIPTION_CHARS) {
      dropped = names.length - i;
      break;
    }
    parts.push(names[i]);
  }

  let head = parts.join(TITLE_SEP);
  if (dropped > 0) head += ` +${dropped} more`;
  if (!note) return truncate(head, MAX_DESCRIPTION_CHARS);
  if (!head) return truncate(note, MAX_DESCRIPTION_CHARS);
  const room = MAX_DESCRIPTION_CHARS - note.length - TITLE_SEP.length;
  return `${truncate(head, Math.max(0, room))}${TITLE_SEP}${note}`;
}

// ── session helpers ─────────────────────────────────────────────────────

type Block = { type?: string; text?: string };
type Entry = { type?: string; message?: { role?: string; content?: unknown } };

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter(
      (b): b is Block =>
        !!b && typeof b === "object" && (b as Block).type === "text" && typeof (b as Block).text === "string",
    )
    .map((b) => (b as Block).text as string)
    .join(" ");
}

function userTexts(entries: Entry[]): string[] {
  const out: string[] = [];
  for (const e of entries) {
    if (e?.type === "message" && e.message?.role === "user") {
      const text = textOf(e.message.content).replace(/\s+/g, " ").trim();
      if (text) out.push(text);
    }
  }
  return out;
}

/**
 * True when no earlier user message was substantive, i.e. the tab has not been named
 * yet for this session. A resumed session already has one, so its tab name is kept.
 */
function isFirstMeaningfulPrompt(entries: Entry[], prompt: string): boolean {
  const normalized = prompt.replace(/\s+/g, " ").trim();
  const texts = userTexts(entries);
  if (texts.length > 0 && texts[texts.length - 1] === normalized) texts.pop();
  return !texts.some((t) => t.length >= MIN_PROMPT_CHARS);
}

// ── extension ───────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  let descriptionNote = "";
  let lastTitle: string | undefined;
  let lastDescription: string | undefined;

  // Rename THIS surface's tab. Never rely on cmux's caller inference (see childEnv).
  const renameTab = async (label: string): Promise<CmuxResult> => {
    const surface = process.env.CMUX_SURFACE_ID;
    const args = ["rename-tab"];
    if (surface) args.push("--surface", surface);
    args.push("--", label);
    return runCmux(args);
  };

  const writeTitle = async (title: string, wsRef?: string): Promise<boolean> => {
    const clean = title.trim();
    if (!clean || clean === lastTitle) return false;
    const args = ["rename-workspace"];
    if (wsRef) args.push("--workspace", wsRef);
    args.push("--", clean);
    const result = await runCmux(args);
    if (!result.ok) return false;
    lastTitle = clean;
    return true;
  };

  const refreshDescription = async (): Promise<void> => {
    const ws = await readWorkspace();
    if (!ws) return;
    const { tabs, currentRef } = await readTabs(ws.ref);
    const description = renderDescription(tabs, currentRef, descriptionNote);
    if (!description) return;
    if (description === (ws.description ?? "").trim() || description === lastDescription) return;
    const result = await runCmux([
      "workspace-action",
      "--action",
      "set-description",
      "--description",
      description,
    ]);
    if (result.ok) lastDescription = description;
  };

  // Base label: the repo/dir name, only when the workspace has no title of its own.
  pi.on("session_start", async (_event, ctx) => {
    if (!inCmuxSurface()) return;
    try {
      descriptionNote = "";
      const ws = await readWorkspace();
      if (!ws) return;
      lastTitle = (ws.custom_title ?? ws.title ?? "").trim() || undefined;
      if (!ws.has_custom_title) {
        const base = basename(ws.current_directory || ctx.cwd || process.cwd());
        if (base) await writeTitle(base, ws.ref);
      }
      await refreshDescription();
    } catch {
      // Never break the agent over a cosmetic sidebar update.
    }
  });

  // /name is an explicit replacement, not a widening.
  pi.on("session_info_changed", async (event) => {
    if (!inCmuxSurface()) return;
    const name = event.name?.trim();
    if (!name) return;
    try {
      const ws = await readWorkspace();
      lastTitle = undefined;
      await writeTitle(name, ws?.ref);
    } catch {
      // Never break the agent over a cosmetic sidebar update.
    }
  });

  // Tab title: named once, from the first meaningful request, then frozen.
  pi.on("before_agent_start", async (event, ctx) => {
    if (!inCmuxSurface()) return;
    try {
      const prompt = event.prompt?.trim() ?? "";
      if (prompt.length < MIN_PROMPT_CHARS || prompt.startsWith("/")) return;
      if (!isFirstMeaningfulPrompt(ctx.sessionManager.getBranch(), prompt)) return;
      const label = deriveTabLabel(prompt);
      if (!label) return;
      await renameTab(label);
    } catch {
      // Never break the agent over a cosmetic sidebar update.
    }
  });

  // The title is deliberately NOT rewritten here: it only widens, on request.
  pi.on("agent_settled", async () => {
    if (!inCmuxSurface()) return;
    try {
      await refreshDescription();
    } catch {
      // Never break the agent over a cosmetic sidebar update.
    }
  });

  pi.registerTool({
    name: "update_cmux_sidebar",
    label: "Update cmux sidebar",
    description:
      "Update the cmux sidebar for this session's workspace.\n" +
      "- `title` / `labels`: labels describing the work. They are APPENDED to the workspace title " +
      "(`<repo/dir> · label, label`). The base label is never removed and nothing existing is replaced, " +
      "so pass short noun labels (e.g. \"vault sync\"), not sentences, and skip anything already shown. " +
      "At most 3 labels fit; extra ones are reported as skipped.\n" +
      "- `tab`: rename this tab (surface). Tabs are free-form and may be changed at will.\n" +
      "- `description`: a short note appended to the auto-generated list of open tabs.\n" +
      "- `replaceTitle`: true only when the user explicitly asks to rename the workspace; `title` then replaces it.",
    parameters: Type.Object({
      title: Type.Optional(Type.String({ description: "Label(s) to append, comma separated" })),
      labels: Type.Optional(Type.Array(Type.String(), { description: "Labels to append" })),
      tab: Type.Optional(Type.String({ description: "New title for this tab (surface)" })),
      description: Type.Optional(Type.String({ description: "Note appended to the open-tab list" })),
      replaceTitle: Type.Optional(Type.Boolean({ description: "Replace the workspace title instead of widening" })),
    }),
    async execute(_toolCallId, params) {
      if (!inCmuxSurface()) {
        return {
          content: [{ type: "text", text: "Not running inside a cmux surface; sidebar update skipped." }],
          details: {},
        };
      }

      const ws = await readWorkspace();
      if (!ws) {
        return {
          content: [{ type: "text", text: "Could not read cmux workspace state; nothing updated." }],
          details: {},
        };
      }

      const notes: string[] = [];
      const incoming = [...(params.labels ?? []), ...(params.title ? params.title.split(",") : [])]
        .map((s) => s.trim())
        .filter(Boolean);

      if (incoming.length > 0) {
        if (params.replaceTitle) {
          const replacement = incoming.map(cleanLabel).filter(Boolean).join(TITLE_SEP);
          if (replacement && (await writeTitle(replacement, ws.ref))) notes.push(`title → ${replacement}`);
        } else {
          const model = parseTitle(ws.custom_title ?? ws.title);
          if (!model.base) model.base = basename(ws.current_directory || process.cwd());
          const { model: widened, added, skipped } = widenTitle(model, incoming);
          if (added.length > 0 && (await writeTitle(renderTitle(widened), ws.ref))) {
            notes.push(`title → ${renderTitle(widened)}`);
          }
          if (skipped.length > 0) notes.push(`already covered or full (not added): ${skipped.join(", ")}`);
        }
      }

      if (params.tab?.trim()) {
        const label = cleanLabel(params.tab);
        if (label) {
          const result = await renameTab(label);
          notes.push(result.ok ? `tab → ${label}` : `tab rename failed: ${result.error}`);
        }
      }

      if (params.description?.trim()) {
        descriptionNote = truncate(params.description.replace(/\s+/g, " ").trim(), 80);
        await refreshDescription();
        notes.push(`description note → ${descriptionNote}`);
      }

      if (notes.length === 0) {
        return {
          content: [{ type: "text", text: "Nothing to update: provide a title, tab and/or description." }],
          details: {},
        };
      }
      return { content: [{ type: "text", text: notes.join("; ") }], details: {} };
    },
  });
}
