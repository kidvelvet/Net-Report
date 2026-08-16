import Foundation
import SQLite3

/// One logged net report, as stored in the database. Column names match the
/// legacy `message_index.csv` so old data imports cleanly.
public struct ReportRecord: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var messageNumber: Int
    public var timestamp: String
    public var userCallSign: String
    public var receivingStation: String
    public var checkins: Int
    public var trafficMessages: Int
    public var pdfFile: String
}

/// SQLite-backed store for net report records — the replacement for the old CSV
/// message index. Kept strictly separate from the operator directory
/// (`UserDatabase`) so erasing report history never touches saved operators.
public final class NetDatabase: SQLiteStore {
    public override init(path: String) throws {
        try super.init(path: path)
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS net_reports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                message_number   INTEGER NOT NULL,
                timestamp        TEXT    NOT NULL,
                user_call_sign   TEXT    NOT NULL,
                receiving_station TEXT   NOT NULL,
                checkins         INTEGER NOT NULL,
                traffic_messages INTEGER NOT NULL,
                pdf_file         TEXT    NOT NULL
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
    }

    // MARK: - Message numbering

    /// Number of logged reports.
    public func reportCount() -> Int {
        (try? scalarInt("SELECT COUNT(*) FROM net_reports;")) ?? 0
    }

    public var isEmpty: Bool { reportCount() == 0 }

    /// Highest `message_number` on record, or nil when there are no reports.
    public func maxMessageNumber() -> Int? {
        guard let value = try? scalarInt("SELECT MAX(message_number) FROM net_reports;",
                                         allowNull: true) else { return nil }
        return value
    }

    /// Largest message number accepted. Well beyond any real net log, but small
    /// enough that incrementing it can never overflow.
    ///
    /// Without this bound a CSV row carrying `Int.max` would be stored, and the
    /// `+ 1` below would trap — crashing the app on *every* launch afterwards,
    /// since opening the data folder reads this value. Clamping keeps a bad
    /// import from becoming unrecoverable from the UI.
    public static let maxAllowedMessageNumber = 100_000_000

    /// The number the next net report should carry:
    /// one past the highest logged, else the configured starting number, else 1.
    public func nextMessageNumber() -> Int {
        if let maxNum = maxMessageNumber() {
            return min(maxNum, Self.maxAllowedMessageNumber - 1) + 1
        }
        if let start = startingNumber() { return start }
        return 1
    }

    // MARK: - Meta (starting number + first-run setup flag)

    public func startingNumber() -> Int? {
        metaValue("starting_number").flatMap(Int.init)
    }

    public func setStartingNumber(_ value: Int) throws {
        // Clamped for the same reason as `maxAllowedMessageNumber`.
        let safe = max(0, min(value, Self.maxAllowedMessageNumber))
        try setMeta("starting_number", String(safe))
        try markSetupDone()
    }

    /// Whether the user has completed (or dismissed) first-run setup.
    public func isSetupDone() -> Bool {
        metaValue("setup_done") == "1"
    }

    public func markSetupDone() throws {
        try setMeta("setup_done", "1")
    }

    private func metaValue(_ key: String) -> String? {
        let stmt = try? prepare("SELECT value FROM meta WHERE key = ?;")
        guard let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func setMeta(_ key: String, _ value: String) throws {
        let stmt = try prepare("INSERT INTO meta(key, value) VALUES(?, ?) " +
                               "ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    // MARK: - Reports

    public func appendReport(
        messageNumber: Int,
        userCallSign: String,
        receivingStation: String,
        checkins: Int,
        trafficMessages: Int,
        pdfPath: String,
        timestamp: Date = Date()
    ) throws {
        let stmt = try prepare("""
            INSERT INTO net_reports
              (message_number, timestamp, user_call_sign, receiving_station,
               checkins, traffic_messages, pdf_file)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(messageNumber))
        bindText(stmt, 2, SQLiteStore.timestampString(timestamp))
        sqlite3_bind_text(stmt, 3, userCallSign, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, receivingStation, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, Int64(checkins))
        sqlite3_bind_int64(stmt, 6, Int64(trafficMessages))
        sqlite3_bind_text(stmt, 7, pdfPath, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    /// All reports, ordered by message number.
    public func allReports() throws -> [ReportRecord] {
        let stmt = try prepare("""
            SELECT id, message_number, timestamp, user_call_sign, receiving_station,
                   checkins, traffic_messages, pdf_file
            FROM net_reports ORDER BY message_number ASC, id ASC;
            """)
        defer { sqlite3_finalize(stmt) }

        var rows: [ReportRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ReportRecord(
                id: sqlite3_column_int64(stmt, 0),
                messageNumber: Int(sqlite3_column_int64(stmt, 1)),
                timestamp: columnText(stmt, 2),
                userCallSign: columnText(stmt, 3),
                receivingStation: columnText(stmt, 4),
                checkins: Int(sqlite3_column_int64(stmt, 5)),
                trafficMessages: Int(sqlite3_column_int64(stmt, 6)),
                pdfFile: columnText(stmt, 7)
            ))
        }
        return rows
    }

    // MARK: - CSV import (legacy message_index.csv format)

    /// Import rows from a CSV in the original `message_index.csv` format. Returns
    /// the number of rows imported. Rows without a numeric message number are
    /// skipped. Marks first-run setup complete.
    @discardableResult
    public func importCSV(from url: URL) throws -> Int {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline).map(String.init)

        // Compile the INSERT once and re-bind per row, rather than re-preparing
        // the same statement for every line in the file.
        let stmt = try prepare("""
            INSERT INTO net_reports
              (message_number, timestamp, user_call_sign, receiving_station,
               checkins, traffic_messages, pdf_file)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(stmt) }

        try exec("BEGIN TRANSACTION;")
        var imported = 0
        do {
            for line in lines {
                let fields = Self.parseCSVLine(line)
                guard fields.count >= 7 else { continue }
                let first = fields[0].trimmingCharacters(in: .whitespaces)
                // Skip the header row, rows without a numeric message number,
                // and absurd values that would overflow later arithmetic.
                guard let messageNumber = Int(first),
                      (0...Self.maxAllowedMessageNumber).contains(messageNumber)
                else { continue }

                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, Int64(messageNumber))
                bindText(stmt, 2, fields[1])
                bindText(stmt, 3, fields[2])
                bindText(stmt, 4, fields[3])
                sqlite3_bind_int64(stmt, 5, Int64(Int(fields[4].trimmingCharacters(in: .whitespaces)) ?? 0))
                sqlite3_bind_int64(stmt, 6, Int64(Int(fields[5].trimmingCharacters(in: .whitespaces)) ?? 0))
                bindText(stmt, 7, fields[6])
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
                imported += 1
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        try markSetupDone()
        return imported
    }

    /// Delete one logged report by row id.
    @discardableResult
    public func deleteReport(id: Int64) throws -> Bool {
        let stmt = try prepare("DELETE FROM net_reports WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
        return sqlite3_changes(db) > 0
    }

    // MARK: - Erase

    /// Delete all reports and reset first-run configuration (starting number and
    /// the setup flag), so the empty-database setup flow appears again. The
    /// operator directory lives in a separate database and is untouched.
    public func eraseAll() throws {
        try exec("DELETE FROM net_reports;")
        try exec("DELETE FROM meta;")
        try? exec("VACUUM;")
    }

    // MARK: - CSV parsing

    /// Split one CSV line into fields, honouring quoted fields and `""` escapes.
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if inQuotes {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":  fields.append(current); current = ""
                default:   current.append(c)
                }
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }
}
