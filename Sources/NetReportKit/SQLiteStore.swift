//
// Net Report - a macOS application for running a local amateur radio net.
// Copyright (C) 2026  kidvelvet (W7SKW)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import SQLite3

public enum DatabaseError: Error, LocalizedError {
    case open(String)
    case sql(String)

    public var errorDescription: String? {
        switch self {
        case .open(let m): return "Database open failed: \(m)"
        case .sql(let m):  return "Database error: \(m)"
        }
    }
}

/// Shared SQLite plumbing for the app's databases (`NetDatabase`, `UserDatabase`).
///
/// Each subclass owns one self-contained `.sqlite` file, so a data folder on a
/// synced or network location can be shared between computers. The default
/// rollback journal is kept deliberately — **not** WAL — because WAL needs shared
/// memory and does not work on network filesystems; the rollback journal
/// collapses back to a single file after each commit.
///
/// Not thread-safe: drive one instance from a single actor (the app uses the
/// main actor). These calls are local and fast.
public class SQLiteStore {
    let db: OpaquePointer?
    public let path: String

    /// Tells SQLite to copy bound text immediately (safe with transient buffers).
    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Open (creating if needed) the database at `path`. Pass `":memory:"` for a
    /// throwaway in-memory database.
    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw DatabaseError.open(message)
        }
        db = handle
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit {
        sqlite3_close(db)
    }

    /// The database file's URL (nil for an in-memory database).
    public var fileURL: URL? {
        path == ":memory:" ? nil : URL(fileURLWithPath: path)
    }

    /// Write a consistent copy of the database to `destination` using SQLite's
    /// online backup API (safe while the database is open).
    public func backup(to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        var dest: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &dest,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              dest != nil else {
            let message = dest.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(dest)
            throw DatabaseError.open(message)
        }
        defer { sqlite3_close(dest) }

        guard let backup = sqlite3_backup_init(dest, "main", db, "main") else {
            throw DatabaseError.sql(String(cString: sqlite3_errmsg(dest)))
        }
        sqlite3_backup_step(backup, -1)
        guard sqlite3_backup_finish(backup) == SQLITE_OK else {
            throw DatabaseError.sql(String(cString: sqlite3_errmsg(dest)))
        }
    }

    /// Replace this database's contents with those of a backup file — the
    /// reverse of `backup(to:)`, done in place through SQLite's backup API so
    /// the open connection stays valid.
    ///
    /// `requiringTable` is checked on the *source* first, so pointing at a
    /// random file (or at the other database's backup) fails cleanly instead of
    /// destroying the data already here.
    public func restore(from source: URL, requiringTable table: String) throws {
        var src: OpaquePointer?
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              src != nil else {
            let message = src.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(src)
            throw DatabaseError.open(message)
        }
        defer { sqlite3_close(src) }

        // Validate before overwriting anything.
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(
            src, "SELECT name FROM sqlite_master WHERE type='table' AND name = ?;",
            -1, &check, nil) == SQLITE_OK else {
            throw DatabaseError.sql("That file is not a readable SQLite database.")
        }
        sqlite3_bind_text(check, 1, table, -1, SQLITE_TRANSIENT)
        let matches = sqlite3_step(check) == SQLITE_ROW
        sqlite3_finalize(check)
        guard matches else {
            throw DatabaseError.sql("That database has no “\(table)” table, so it isn't a "
                                    + "Net Report backup of this kind.")
        }

        guard let restore = sqlite3_backup_init(db, "main", src, "main") else {
            throw lastError()
        }
        sqlite3_backup_step(restore, -1)
        guard sqlite3_backup_finish(restore) == SQLITE_OK else { throw lastError() }
    }

    // MARK: - Low-level helpers

    func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            throw DatabaseError.sql(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError()
        }
        return stmt
    }

    func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    /// Run a query returning a single integer. With `allowNull`, a SQL NULL
    /// result (e.g. MAX over no rows) returns nil.
    func scalarInt(_ sql: String, allowNull: Bool = false) throws -> Int? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw lastError() }
        if allowNull && sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    func lastError() -> DatabaseError {
        DatabaseError.sql(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }

    /// Shared formatter for stored timestamps. Built once: `DateFormatter` is
    /// costly to create and is safe to reuse for formatting once configured.
    /// This runs per row during a CSV import, so allocating one each time is a
    /// measurable waste.
    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt
    }()

    /// Current time as the `yyyy-MM-dd HH:mm:ss` string both databases store.
    static func timestampString(_ date: Date = Date()) -> String {
        timestampFormatter.string(from: date)
    }
}
