import Foundation
import SQLite3

/// 系统 SQLite3 薄封装：零第三方依赖，schema 与桌面端 database.py 一致
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) {
        var db: OpaquePointer?
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "nil"
            if let db { sqlite3_close(db) }
            fatalError("sqlite3_open failed: \(msg)")
        }
        handle = db
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA foreign_keys=ON", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA busy_timeout=5000", nil, nil, nil)
    }

    func execute(_ sql: String, _ params: [Any?] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            logError(sql)
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        if sqlite3_step(stmt) != SQLITE_DONE {
            logError(sql)
        }
    }

    func scalarInt(_ sql: String, _ params: [Any?] = []) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            logError(sql)
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            logError(sql)
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_count(stmt)
            var row: [String: Any] = [:]
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, i))
                row[name] = columnValue(stmt, i)
            }
            rows.append(row)
        }
        return rows
    }

    func lastInsertRowId() -> Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    func transaction(_ block: () -> Void) {
        sqlite3_exec(handle, "BEGIN", nil, nil, nil)
        block()
        sqlite3_exec(handle, "COMMIT", nil, nil, nil)
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [Any?]) {
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case nil:
                sqlite3_bind_null(stmt, idx)
            case let v as Int:
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64:
                sqlite3_bind_int64(stmt, idx, v)
            case let v as Double:
                sqlite3_bind_double(stmt, idx, v)
            case let v as Bool:
                sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as String:
                sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func columnValue(_ stmt: OpaquePointer?, _ i: Int32) -> Any {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER:
            return Int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT:
            return sqlite3_column_double(stmt, i)
        case SQLITE_TEXT:
            guard let ptr = sqlite3_column_text(stmt, i) else { return NSNull() }
            return String(cString: ptr)
        case SQLITE_NULL:
            return NSNull()
        default:
            guard let ptr = sqlite3_column_blob(stmt, i) else { return NSNull() }
            let n = sqlite3_column_bytes(stmt, i)
            return Data(bytes: ptr, count: Int(n))
        }
    }

    private func logError(_ sql: String) {
        guard let h = handle else { return }
        let msg = String(cString: sqlite3_errmsg(h))
        print("OhMyMeme/SQLite error: \(msg) | \(sql)")
    }
}