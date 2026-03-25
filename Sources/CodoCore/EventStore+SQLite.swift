import Foundation
import SQLite3

// MARK: - Errors

public enum EventStoreError: Error, CustomStringConvertible {
    case openFailed(reason: String)
    case notOpen
    case executeFailed(reason: String)
    case prepareFailed(reason: String)
    case stepFailed(reason: String)

    public var description: String {
        switch self {
        case .openFailed(let reason): "EventStore open failed: \(reason)"
        case .notOpen: "EventStore not open"
        case .executeFailed(let reason): "EventStore execute failed: \(reason)"
        case .prepareFailed(let reason): "EventStore prepare failed: \(reason)"
        case .stepFailed(let reason): "EventStore step failed: \(reason)"
        }
    }
}

// MARK: - SQLite Helpers

extension EventStore {
    enum SQLiteParam {
        case text(String)
        case textOrNull(String?)
        case int(Int)
        case intOrNull(Int?)
    }

    /// Execute raw SQL (for PRAGMA, multi-statement DDL, etc.)
    func executeSql(_ sql: String) throws {
        guard let database else { throw EventStoreError.notOpen }
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw EventStoreError.executeFailed(reason: msg)
        }
    }

    /// Prepare a statement, bind parameters, execute (step), and finalize.
    @discardableResult
    func prepareAndBind(
        _ sql: String,
        params: [SQLiteParam]
    ) throws -> Int {
        guard let database else { throw EventStoreError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw EventStoreError.prepareFailed(
                reason: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(stmt) }

        bindParams(params, to: stmt)

        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw EventStoreError.stepFailed(
                reason: String(cString: sqlite3_errmsg(database))
            )
        }
        return Int(sqlite3_changes(database))
    }

    /// Prepare and bind a SELECT statement, returning the statement for iteration.
    func prepareQuery(
        _ sql: String,
        params: [SQLiteParam]
    ) throws -> OpaquePointer {
        guard let database else { throw EventStoreError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw EventStoreError.prepareFailed(
                reason: String(cString: sqlite3_errmsg(database))
            )
        }

        bindParams(params, to: stmt)
        return stmt
    }

    // MARK: - Bind

    private func bindParams(_ params: [SQLiteParam], to stmt: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (idx, param) in params.enumerated() {
            let col = Int32(idx + 1)
            switch param {
            case .text(let str):
                sqlite3_bind_text(stmt, col, str, -1, transient)
            case .textOrNull(let str):
                if let str {
                    sqlite3_bind_text(stmt, col, str, -1, transient)
                } else {
                    sqlite3_bind_null(stmt, col)
                }
            case .int(let num):
                sqlite3_bind_int(stmt, col, Int32(num))
            case .intOrNull(let num):
                if let num {
                    sqlite3_bind_int(stmt, col, Int32(num))
                } else {
                    sqlite3_bind_null(stmt, col)
                }
            }
        }
    }

    // MARK: - Column Readers

    func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: cStr)
    }

    func columnTextOrNil(
        _ stmt: OpaquePointer,
        _ idx: Int32
    ) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        guard let cStr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cStr)
    }

    func columnIntOrNil(
        _ stmt: OpaquePointer,
        _ idx: Int32
    ) -> Int? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, idx))
    }

    // MARK: - Date Helpers

    static let iso8601Fmt: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    static func dateToString(_ date: Date) -> String {
        iso8601Fmt.string(from: date)
    }

    static func stringToDate(_ string: String) -> Date {
        iso8601Fmt.date(from: string) ?? Date()
    }

    func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    func daysAgoString(_ days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let date = Calendar.current.date(
            byAdding: .day, value: -days, to: Date()
        ) ?? Date()
        return formatter.string(from: date)
    }
}
