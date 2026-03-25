import { realpathSync } from "node:fs";
import type { HookEvent, HookEventName } from "./types";
import { extractCommand } from "./types";
import { classifyEvent } from "./classifier";
import { createLogger } from "./logger";

const log = createLogger("state");

export interface ProjectState {
  cwd: string;
  sessionId: string | null;
  task: string | null;
  lastStatus: string | null;
  model: string | null;
  recentNotifications: Array<{ title: string; body?: string; time: number }>;
  lastEventTime: number;
  sessionActive: boolean;
  transcriptLastReadOffset: number;
}

export interface BufferedEvent {
  timestamp: number;
  hookType: HookEventName;
  sessionId: string;
  cwd?: string;
  summary: string;
  raw: Record<string, unknown>;
}

export interface StateStore {
  projects: Map<string, ProjectState>;
  events: BufferedEvent[];
  sessionToCwd: Map<string, string>; // session_id → canonical cwd
  summary: string;
}

const MAX_EVENTS = 200;
const GENERIC_TASK_PATTERNS = [
  /^done$/i,
  /^completed$/i,
  /^finished$/i,
  /^ok$/i,
];

export function createStateStore(): StateStore {
  return {
    projects: new Map(),
    events: [],
    sessionToCwd: new Map(),
    summary: "",
  };
}

export function canonicalizePath(cwd: string): string {
  try {
    return realpathSync(cwd);
  } catch {
    return cwd;
  }
}

export function getProject(
  store: StateStore,
  cwd: string,
): ProjectState | undefined {
  return store.projects.get(canonicalizePath(cwd));
}

function getOrCreateProject(store: StateStore, cwd: string): ProjectState {
  const key = canonicalizePath(cwd);
  let project = store.projects.get(key);
  if (!project) {
    project = {
      cwd: key,
      sessionId: null,
      task: null,
      lastStatus: null,
      model: null,
      recentNotifications: [],
      lastEventTime: Date.now(),
      sessionActive: false,
      transcriptLastReadOffset: 0,
    };
    store.projects.set(key, project);
  }
  return project;
}

function isGenericTask(message: unknown): boolean {
  if (typeof message !== "string") return false;
  return GENERIC_TASK_PATTERNS.some((p) => p.test(message.trim()));
}

function summarizeEvent(event: HookEvent): string {
  switch (event._hook) {
    case "stop":
      return `stop: ${truncate(event.last_assistant_message, 500)}`;
    case "notification":
      return `notification: ${event.title ?? "untitled"} — ${truncate(event.message, 200)}`;
    case "post-tool-use":
      return `tool: ${event.tool_name ?? "unknown"} — ${truncate(extractCommand(event), 200)} → ${truncate(event.tool_response, 300)}`;
    case "post-tool-use-failure":
      return `tool-fail: ${event.tool_name ?? "unknown"} — ${truncate(event.error ?? "", 300)}`;
    case "session-start":
      return `session-start: ${event.model ?? "unknown model"}`;
    case "session-end":
      return "session-end";
    default:
      return `${event._hook}`;
  }
}

function truncate(s: unknown, max: number): string {
  if (typeof s !== "string") return s == null ? "" : String(s).slice(0, max);
  return s.length <= max ? s : `${s.slice(0, max)}...`;
}

export function updateState(store: StateStore, event: HookEvent): void {
  const cwd = event.cwd;
  const { tier } = classifyEvent(event);

  // Noise events: no state change at all
  if (tier === "noise") {
    log.debug("updateState", "noise early return", { hook: event._hook });
    return;
  }

  // Resolve cwd: canonicalize if present, otherwise fall back to sessionToCwd
  const resolvedCwd =
    (cwd ? canonicalizePath(cwd) : undefined) ??
    store.sessionToCwd.get(event.session_id);

  // Buffer the event (contextual and important)
  const buffered: BufferedEvent = {
    timestamp: Date.now(),
    hookType: event._hook,
    sessionId: event.session_id,
    cwd: resolvedCwd,
    summary: summarizeEvent(event),
    raw: event as Record<string, unknown>,
  };
  store.events.push(buffered);
  if (store.events.length > MAX_EVENTS) {
    store.events.splice(0, store.events.length - MAX_EVENTS);
  }

  log.debug("updateState", "event buffered", {
    hook: event._hook,
    buffer_size: String(store.events.length),
    summary: buffered.summary.slice(0, 80),
  });

  // Update project state based on hook type
  if (!resolvedCwd) return; // session-end may lack cwd; resolvedCwd uses sessionToCwd fallback

  const project = getOrCreateProject(store, resolvedCwd);
  project.lastEventTime = Date.now();

  switch (event._hook) {
    case "session-start":
      if (cwd) {
        store.sessionToCwd.set(event.session_id, resolvedCwd);
      }
      project.sessionId = event.session_id;
      project.model = typeof event.model === "string" ? event.model : null;
      project.sessionActive = true;
      log.info("updateState", "session started", {
        cwd: project.cwd,
        model: project.model ?? "unknown",
      });
      break;

    case "session-end":
      project.sessionActive = false;
      log.info("updateState", "session ended", { cwd: project.cwd });
      break;

    case "stop": {
      const msg = event.last_assistant_message;
      if (typeof msg === "string" && msg && !isGenericTask(msg)) {
        project.task = truncate(msg, 200);
      }
      break;
    }

    case "notification":
      project.recentNotifications.push({
        title: typeof event.title === "string" ? event.title : "Untitled",
        body:
          typeof event.message === "string"
            ? truncate(event.message, 200)
            : undefined,
        time: Date.now(),
      });
      // Keep last 10 notifications
      if (project.recentNotifications.length > 10) {
        project.recentNotifications.splice(
          0,
          project.recentNotifications.length - 10,
        );
      }
      break;

    case "post-tool-use":
      if (tier === "important") {
        project.lastStatus = truncate(event.tool_response, 200);
        log.debug("updateState", "lastStatus updated", {
          hook: event._hook,
          status: (project.lastStatus ?? "").slice(0, 60),
        });
      }
      break;

    case "post-tool-use-failure":
      project.lastStatus = truncate(event.error, 200);
      log.debug("updateState", "lastStatus updated (failure)", {
        hook: event._hook,
        status: (project.lastStatus ?? "").slice(0, 60),
      });
      break;
  }
}

export function evictStaleProjects(
  store: StateStore,
  maxAgeMs: number,
): void {
  const now = Date.now();
  for (const [key, project] of store.projects) {
    if (now - project.lastEventTime > maxAgeMs) {
      store.projects.delete(key);
    }
  }

  // Prune sessionToCwd: keep sessions still in the event buffer
  // OR still attached to a surviving project (active session with no recent events)
  const liveSessionIds = new Set(store.events.map((e) => e.sessionId));
  for (const [, project] of store.projects) {
    if (project.sessionId) liveSessionIds.add(project.sessionId);
  }
  for (const sessionId of store.sessionToCwd.keys()) {
    if (!liveSessionIds.has(sessionId)) {
      store.sessionToCwd.delete(sessionId);
    }
  }
}

export function serializeForPrompt(
  store: StateStore,
  charBudget: number = 600_000,
): string {
  let remaining = charBudget;
  const parts: string[] = [];

  // ── Step 1: Active Projects summary ──
  if (store.projects.size > 0) {
    const projectLines: string[] = ["## Active Projects\n"];
    // Sort by lastEventTime desc so tight budgets keep the most recent projects
    const sortedProjects = [...store.projects.values()].sort(
      (a, b) => b.lastEventTime - a.lastEventTime,
    );
    for (const project of sortedProjects) {
      const line = `- **${project.cwd}** (session: ${project.sessionActive ? "active" : "inactive"})`;
      const extras: string[] = [];
      if (project.task) extras.push(`  Task: ${project.task}`);
      if (project.model) extras.push(`  Model: ${project.model}`);
      if (project.lastStatus)
        extras.push(`  Last status: ${project.lastStatus}`);

      const chunk = [line, ...extras].join("\n");
      if (chunk.length > remaining) break;
      projectLines.push(chunk);
      remaining -= chunk.length;
    }
    if (projectLines.length > 1) {
      parts.push(projectLines.join("\n"));
    }
  }

  // ── Step 2: Notification history (priority reserve) ──
  // For each active project, render most recent 3 notifications BEFORE event selection
  // to guarantee de-duplication context is always available
  const notifByProject = new Map<string, string[]>();
  for (const [, project] of store.projects) {
    const notifs = project.recentNotifications.slice(-3);
    if (notifs.length === 0) continue;

    const lines: string[] = [];
    for (const n of notifs) {
      const time = new Date(n.time).toISOString();
      const bodyPart = n.body ? ` — ${n.body}` : "";
      lines.push(`- [${time}] ${n.title}${bodyPart}`);
    }
    const chunk = lines.join("\n");
    if (chunk.length <= remaining) {
      notifByProject.set(project.cwd, lines);
      remaining -= chunk.length;
    }
  }

  // ── Step 3: Event selection — per-event from newest to oldest ──
  const selectedIndices: number[] = [];
  for (let i = store.events.length - 1; i >= 0; i--) {
    const event = store.events[i];
    const time = new Date(event.timestamp).toISOString();
    const line = `- [${time}] ${event.summary}`;
    if (line.length > remaining) break;
    selectedIndices.push(i);
    remaining -= line.length;
  }
  // Reverse to chronological order
  selectedIndices.reverse();

  // ── Step 4: Render — group selected events by cwd ──
  // Collect all cwds that have events or notifications
  const eventsByCwd = new Map<string, BufferedEvent[]>();
  for (const idx of selectedIndices) {
    const event = store.events[idx];
    const key = event.cwd ?? "unknown";
    let list = eventsByCwd.get(key);
    if (!list) {
      list = [];
      eventsByCwd.set(key, list);
    }
    list.push(event);
  }

  // Merge notification cwds into the rendering set
  const allCwds = new Set([...eventsByCwd.keys(), ...notifByProject.keys()]);

  if (allCwds.size > 0) {
    parts.push("\n## Event History\n");
    for (const cwd of allCwds) {
      parts.push(`### ${cwd}\n`);

      // Sent notifications for this project
      const notifLines = notifByProject.get(cwd);
      if (notifLines && notifLines.length > 0) {
        parts.push("#### Sent Notifications");
        parts.push(...notifLines);
        parts.push("");
      }

      // Event timeline
      const events = eventsByCwd.get(cwd);
      if (events && events.length > 0) {
        parts.push("#### Event Timeline");
        for (const event of events) {
          const time = new Date(event.timestamp).toISOString();
          parts.push(`- [${time}] ${event.summary}`);
        }
        parts.push("");
      }
    }
  }

  // Summary
  if (store.summary) {
    parts.push(`\n## Summary\n${store.summary}`);
  }

  return parts.join("\n");
}
