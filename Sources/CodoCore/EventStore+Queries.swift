import Foundation
import SQLite3

// MARK: - Query Methods

extension EventStore {
    /// Query events with optional filters. Returns newest first.
    public func queryEvents(
        project: String? = nil,
        type: String? = nil,
        since: Date? = nil,
        limit: Int = 200
    ) -> [EventRecord] {
        queue.sync {
            var conditions: [String] = []
            var params: [SQLiteParam] = []

            if let project {
                conditions.append("project_cwd = ?")
                params.append(.text(canonicalizeCwd(project)))
            }
            if let type {
                conditions.append("type = ?")
                params.append(.text(type))
            }
            if let since {
                conditions.append("timestamp >= ?")
                params.append(.text(Self.dateToString(since)))
            }

            let filter = conditions.isEmpty
                ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
            SELECT timestamp, type, hook_type, session_id,
                   project_cwd, project_name, summary, raw_json
            FROM events \(filter)
            ORDER BY timestamp DESC LIMIT ?
            """
            params.append(.int(limit))

            guard let stmt = try? prepareQuery(sql, params: params)
            else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [EventRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(EventRecord(
                    timestamp: Self.stringToDate(columnText(stmt, 0)),
                    type: columnText(stmt, 1),
                    hookType: columnTextOrNil(stmt, 2),
                    sessionId: columnTextOrNil(stmt, 3),
                    projectCwd: columnTextOrNil(stmt, 4),
                    projectName: columnTextOrNil(stmt, 5),
                    summary: columnText(stmt, 6),
                    rawJson: columnTextOrNil(stmt, 7)
                ))
            }
            return results
        }
    }

    /// Query guardian decisions with optional filters. Newest first.
    public func queryDecisions(
        project: String? = nil,
        since: Date? = nil,
        limit: Int = 100
    ) -> [DecisionRecord] {
        queue.sync {
            var conditions: [String] = []
            var params: [SQLiteParam] = []

            if let project {
                conditions.append("project_cwd = ?")
                params.append(.text(canonicalizeCwd(project)))
            }
            if let since {
                conditions.append("timestamp >= ?")
                params.append(.text(Self.dateToString(since)))
            }

            let filter = conditions.isEmpty
                ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
            SELECT timestamp, session_id, project_cwd,
                   hook_type, tier, action, title, reason,
                   model, prompt_tokens, completion_tokens,
                   latency_ms
            FROM guardian_decisions \(filter)
            ORDER BY timestamp DESC LIMIT ?
            """
            params.append(.int(limit))

            guard let stmt = try? prepareQuery(sql, params: params)
            else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [DecisionRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(DecisionRecord(
                    timestamp: Self.stringToDate(columnText(stmt, 0)),
                    sessionId: columnTextOrNil(stmt, 1),
                    projectCwd: columnTextOrNil(stmt, 2),
                    hookType: columnTextOrNil(stmt, 3),
                    tier: columnTextOrNil(stmt, 4),
                    action: columnText(stmt, 5),
                    title: columnTextOrNil(stmt, 6),
                    reason: columnTextOrNil(stmt, 7),
                    model: columnTextOrNil(stmt, 8),
                    promptTokens: columnIntOrNil(stmt, 9),
                    completionTokens: columnIntOrNil(stmt, 10),
                    latencyMs: columnIntOrNil(stmt, 11)
                ))
            }
            return results
        }
    }

    /// Query daily stats with optional project filter.
    public func dailyStats(
        project: String? = nil,
        days: Int = 7
    ) -> [DailyStatsRecord] {
        queue.sync {
            var conditions: [String] = ["date >= ?"]
            var params: [SQLiteParam] = [.text(daysAgoString(days))]

            if let project {
                conditions.append("project_cwd = ?")
                params.append(.text(canonicalizeCwd(project)))
            }

            let filter = "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
            SELECT date, project_cwd, events_count,
                   sent_count, suppressed_count,
                   prompt_tokens, completion_tokens, llm_calls
            FROM daily_stats \(filter)
            ORDER BY date DESC
            """

            guard let stmt = try? prepareQuery(sql, params: params)
            else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [DailyStatsRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(DailyStatsRecord(
                    date: columnText(stmt, 0),
                    projectCwd: columnText(stmt, 1),
                    eventsCount: Int(sqlite3_column_int(stmt, 2)),
                    sentCount: Int(sqlite3_column_int(stmt, 3)),
                    suppressedCount: Int(sqlite3_column_int(stmt, 4)),
                    promptTokens: Int(sqlite3_column_int(stmt, 5)),
                    completionTokens: Int(sqlite3_column_int(stmt, 6)),
                    llmCalls: Int(sqlite3_column_int(stmt, 7))
                ))
            }
            return results
        }
    }

    /// Aggregate today's daily_stats across all projects.
    public func todayStats() -> TodayStatsSummary {
        queue.sync {
            let today = todayString()
            let sql = """
            SELECT COALESCE(SUM(sent_count), 0),
                   COALESCE(SUM(suppressed_count), 0),
                   COALESCE(SUM(prompt_tokens), 0),
                   COALESCE(SUM(completion_tokens), 0)
            FROM daily_stats WHERE date = ?
            """
            guard let stmt = try? prepareQuery(sql, params: [.text(today)])
            else { return .empty }
            defer { sqlite3_finalize(stmt) }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return TodayStatsSummary(
                    sent: Int(sqlite3_column_int(stmt, 0)),
                    suppressed: Int(sqlite3_column_int(stmt, 1)),
                    promptTokens: Int(sqlite3_column_int(stmt, 2)),
                    completionTokens: Int(sqlite3_column_int(stmt, 3))
                )
            }
            return .empty
        }
    }

    /// Load all projects from the database.
    public func loadProjects() -> [ProjectRecord] {
        queue.sync {
            let sql = """
            SELECT cwd, name, custom_logo_path, last_seen
            FROM projects ORDER BY last_seen DESC
            """
            guard let stmt = try? prepareQuery(sql, params: [])
            else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [ProjectRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(ProjectRecord(
                    cwd: columnText(stmt, 0),
                    name: columnText(stmt, 1),
                    customLogoPath: columnTextOrNil(stmt, 2),
                    lastSeen: Self.stringToDate(columnText(stmt, 3))
                ))
            }
            return results
        }
    }
}
