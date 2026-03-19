import { realpathSync } from "node:fs";
import type { HookEvent, HookEventName } from "./types";
import { extractCommand } from "./types";
import { classifyEvent } from "./classifier";

export interface ProjectState {
  cwd: string;
  sessionId: string | null;
  task: string | null;
  lastStatus: string | null;
  model: string | null;
  recentNotifications: Array<{ title: string; time: number }>;
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
  summary: string;
}

const MAX_EVENTS = 50;
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

function isGenericTask(message: string): boolean {
  return GENERIC_TASK_PATTERNS.some((p) => p.test(message.trim()));
}

function summarizeEvent(event: HookEvent): string {
  switch (event._hook) {
    case "stop":
      return `stop: ${truncate(event.last_assistant_message as string, 80)}`;
    case "notification":
      return `notification: ${event.title ?? "untitled"}`;
    case "post-tool-use":
      return `tool: ${event.tool_name ?? "unknown"} — ${truncate(extractCommand(event), 60)}`;
    case "post-tool-use-failure":
      return `tool-fail: ${event.tool_name ?? "unknown"} — ${truncate(event.error as string ?? "", 60)}`;
    case "session-start":
      return `session-start: ${event.model ?? "unknown model"}`;
    case "session-end":
      return "session-end";
    default:
      return `${event._hook}`;
  }
}

function truncate(s: string | undefined | null, max: number): string {
  if (!s) return "";
  return s.length <= max ? s : `${s.slice(0, max)}...`;
}

export function updateState(store: StateStore, event: HookEvent): void {
  const cwd = event.cwd;
  const { tier } = classifyEvent(event);

  // Noise events: no state change at all
  if (tier === "noise") return;

  // Buffer the event (contextual and important)
  const buffered: BufferedEvent = {
    timestamp: Date.now(),
    hookType: event._hook,
    sessionId: event.session_id,
    cwd: cwd,
    summary: summarizeEvent(event),
    raw: event as Record<string, unknown>,
  };
  store.events.push(buffered);
  if (store.events.length > MAX_EVENTS) {
    store.events.splice(0, store.events.length - MAX_EVENTS);
  }

  // Update project state based on hook type
  if (!cwd) return; // session-end may lack cwd

  const project = getOrCreateProject(store, cwd);
  project.lastEventTime = Date.now();

  switch (event._hook) {
    case "session-start":
      project.sessionId = event.session_id;
      project.model = (event.model as string) ?? null;
      project.sessionActive = true;
      break;

    case "session-end":
      project.sessionActive = false;
      break;

    case "stop": {
      const msg = event.last_assistant_message as string | undefined;
      if (msg && !isGenericTask(msg)) {
        // Only overwrite task if the new message is specific
        if (!project.task || !isGenericTask(msg)) {
          project.task = truncate(msg, 200);
        }
      }
      break;
    }

    case "notification":
      project.recentNotifications.push({
        title: (event.title as string) ?? "Untitled",
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
        project.lastStatus = truncate(
          event.tool_response as string,
          200,
        );
      }
      break;

    case "post-tool-use-failure":
      project.lastStatus = truncate(event.error as string, 200);
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
}

export function serializeForPrompt(
  store: StateStore,
  maxEvents: number = MAX_EVENTS,
): string {
  const parts: string[] = [];

  // Projects
  if (store.projects.size > 0) {
    parts.push("## Active Projects\n");
    for (const [, project] of store.projects) {
      parts.push(
        `- **${project.cwd}** (session: ${project.sessionActive ? "active" : "inactive"})`,
      );
      if (project.task) parts.push(`  Task: ${project.task}`);
      if (project.model) parts.push(`  Model: ${project.model}`);
      if (project.lastStatus)
        parts.push(`  Last status: ${project.lastStatus}`);
    }
  }

  // Events
  const recentEvents = store.events.slice(-maxEvents);
  if (recentEvents.length > 0) {
    parts.push("\n## Recent Events\n");
    for (const event of recentEvents) {
      const time = new Date(event.timestamp).toISOString();
      parts.push(`- [${time}] ${event.summary}`);
    }
  }

  // Summary
  if (store.summary) {
    parts.push(`\n## Summary\n${store.summary}`);
  }

  return parts.join("\n");
}
