import Foundation
import SQLite3

/// SQLite-backed persistent event store for dashboard data.
/// Thread-safe via serial DispatchQueue. Uses WAL mode for concurrent read/write.
public final class EventStore: @unchecked Sendable {
    var database: OpaquePointer?
    let queue = DispatchQueue(label: "ai.hexly.codo.eventstore")

    // MARK: - Init / Close

    /// Initialize the event store. Pass `:memory:` for in-memory testing.
    public init(path: String = "\(NSHomeDirectory())/.codo/codo.db") throws {
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
        }

        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &dbPointer, flags, nil)
        guard result == SQLITE_OK, let dbPointer else {
            let msg = dbPointer.flatMap {
                String(cString: sqlite3_errmsg($0))
            } ?? "unknown"
            if let dbPointer { sqlite3_close(dbPointer) }
            throw EventStoreError.openFailed(reason: msg)
        }
        self.database = dbPointer

        try executeSql("PRAGMA journal_mode=WAL")
        try createSchema()
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    /// Close the database connection explicitly.
    public func close() {
        queue.sync {
            if let database {
                sqlite3_close(database)
                self.database = nil
            }
        }
    }

    // MARK: - Schema

    private func createSchema() throws {
        try executeSql("""
        CREATE TABLE IF NOT EXISTS events (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp   TEXT    NOT NULL,
            type        TEXT    NOT NULL,
            hook_type   TEXT,
            session_id  TEXT,
            project_cwd TEXT,
            project_name TEXT,
            summary     TEXT,
            raw_json    TEXT,
            created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_events_project
            ON events(project_cwd, timestamp);
        CREATE INDEX IF NOT EXISTS idx_events_type
            ON events(type, timestamp);
        CREATE INDEX IF NOT EXISTS idx_events_session
            ON events(session_id);

        CREATE TABLE IF NOT EXISTS guardian_decisions (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp       TEXT    NOT NULL,
            session_id      TEXT,
            project_cwd     TEXT,
            hook_type       TEXT,
            tier            TEXT,
            action          TEXT,
            title           TEXT,
            reason          TEXT,
            model           TEXT,
            prompt_tokens   INTEGER,
            completion_tokens INTEGER,
            latency_ms      INTEGER,
            created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_decisions_project
            ON guardian_decisions(project_cwd, timestamp);

        CREATE TABLE IF NOT EXISTS daily_stats (
            date            TEXT    NOT NULL,
            project_cwd     TEXT    NOT NULL,
            events_count    INTEGER NOT NULL DEFAULT 0,
            sent_count      INTEGER NOT NULL DEFAULT 0,
            suppressed_count INTEGER NOT NULL DEFAULT 0,
            prompt_tokens   INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            llm_calls       INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (date, project_cwd)
        );

        CREATE TABLE IF NOT EXISTS projects (
            cwd             TEXT    PRIMARY KEY,
            name            TEXT    NOT NULL,
            custom_logo_path TEXT,
            last_seen       TEXT    NOT NULL,
            created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
        );
        """)
    }

    // MARK: - Insert Event

    /// Insert an event record. Canonicalizes projectCwd before insert.
    public func insertEvent(_ event: EventRecord) {
        queue.sync {
            let cwd = event.projectCwd.map { canonicalizeCwd($0) }
            let sql = """
            INSERT INTO events
            (timestamp, type, hook_type, session_id,
             project_cwd, project_name, summary, raw_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            _ = try? prepareAndBind(sql, params: [
                .text(Self.dateToString(event.timestamp)),
                .text(event.type),
                .textOrNull(event.hookType),
                .textOrNull(event.sessionId),
                .textOrNull(cwd),
                .textOrNull(event.projectName),
                .text(event.summary),
                .textOrNull(event.rawJson)
            ])
        }
    }

    // MARK: - Insert Decision

    /// Insert a guardian decision record. Also updates daily_stats.
    public func insertDecision(_ decision: DecisionRecord) {
        queue.sync {
            let cwd = decision.projectCwd.map { canonicalizeCwd($0) }
            let sql = """
            INSERT INTO guardian_decisions
            (timestamp, session_id, project_cwd, hook_type, tier,
             action, title, reason, model,
             prompt_tokens, completion_tokens, latency_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            _ = try? prepareAndBind(sql, params: [
                .text(Self.dateToString(decision.timestamp)),
                .textOrNull(decision.sessionId),
                .textOrNull(cwd),
                .textOrNull(decision.hookType),
                .textOrNull(decision.tier),
                .text(decision.action),
                .textOrNull(decision.title),
                .textOrNull(decision.reason),
                .textOrNull(decision.model),
                .intOrNull(decision.promptTokens),
                .intOrNull(decision.completionTokens),
                .intOrNull(decision.latencyMs)
            ])

            updateDailyStats(
                projectCwd: cwd ?? DailyStatsRecord.unattributed,
                action: decision.action,
                promptTokens: decision.promptTokens ?? 0,
                completionTokens: decision.completionTokens ?? 0
            )
        }
    }

    /// Increment daily_stats counters for the given project.
    private func updateDailyStats(
        projectCwd: String,
        action: String,
        promptTokens: Int,
        completionTokens: Int
    ) {
        let today = todayString()
        let isSend = action == "send" ? 1 : 0
        let isSuppressed = action == "suppress" ? 1 : 0

        let sql = """
        INSERT INTO daily_stats
        (date, project_cwd, events_count,
         sent_count, suppressed_count,
         prompt_tokens, completion_tokens, llm_calls)
        VALUES (?, ?, 1, ?, ?, ?, ?, 1)
        ON CONFLICT(date, project_cwd) DO UPDATE SET
            events_count = events_count + 1,
            sent_count = sent_count + ?,
            suppressed_count = suppressed_count + ?,
            prompt_tokens = prompt_tokens + ?,
            completion_tokens = completion_tokens + ?,
            llm_calls = llm_calls + 1
        """
        _ = try? prepareAndBind(sql, params: [
            .text(today),
            .text(projectCwd),
            .int(isSend),
            .int(isSuppressed),
            .int(promptTokens),
            .int(completionTokens),
            .int(isSend),
            .int(isSuppressed),
            .int(promptTokens),
            .int(completionTokens)
        ])
    }

    // MARK: - Upsert Project

    /// Upsert a project record. Canonicalizes cwd before insert.
    public func upsertProject(_ project: ProjectRecord) {
        queue.sync {
            let cwd = canonicalizeCwd(project.cwd)
            let sql = """
            INSERT INTO projects (cwd, name, custom_logo_path, last_seen)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(cwd) DO UPDATE SET
                name = excluded.name,
                custom_logo_path = excluded.custom_logo_path,
                last_seen = excluded.last_seen
            """
            _ = try? prepareAndBind(sql, params: [
                .text(cwd),
                .text(project.name),
                .textOrNull(project.customLogoPath),
                .text(Self.dateToString(project.lastSeen))
            ])
        }
    }

    // MARK: - Vacuum

    /// Delete events and decisions older than `keepDays` days.
    public func vacuum(keepDays: Int = 30) {
        queue.sync {
            let cutoff = daysAgoString(keepDays)
            _ = try? prepareAndBind(
                "DELETE FROM events WHERE timestamp < ?",
                params: [.text(cutoff)]
            )
            _ = try? prepareAndBind(
                "DELETE FROM guardian_decisions WHERE timestamp < ?",
                params: [.text(cutoff)]
            )
            let dateCutoff = String(cutoff.prefix(10))
            _ = try? prepareAndBind(
                "DELETE FROM daily_stats WHERE date < ?",
                params: [.text(dateCutoff)]
            )
        }
    }
}
