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

/// A known operator in the local directory: everything QRZ told us, plus the
/// operator's own additions (nickname and persistent notes).
///
/// Only *persistent* notes live here. A check-in's temporary notes apply to one
/// net and are never written to the database.
public struct UserEntry: Sendable, Equatable, Identifiable {
    public var callSign: String
    public var name: String
    public var firstName: String
    public var lastName: String
    public var nickname: String
    public var street: String
    public var city: String
    public var county: String
    public var state: String
    public var persistentNotes: String
    public var updatedAt: String

    public var id: String { callSign }

    public init(
        callSign: String,
        name: String,
        firstName: String = "",
        lastName: String = "",
        nickname: String = "",
        street: String = "",
        city: String = "",
        county: String = "",
        state: String = "",
        persistentNotes: String = "",
        updatedAt: String = ""
    ) {
        self.callSign = callSign
        self.name = name
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.street = street
        self.city = city
        self.county = county
        self.state = state
        self.persistentNotes = persistentNotes
        self.updatedAt = updatedAt
    }

    /// The directory entry as a station record, for the report/NTS code paths.
    public var record: HamRecord {
        HamRecord(
            callSign: callSign,
            name: name,
            firstName: firstName,
            lastName: lastName,
            street: street,
            city: city,
            county: county,
            state: state
        )
    }

    /// Build an entry from a QRZ lookup, carrying local nickname/notes.
    public init(record: HamRecord, nickname: String = "", persistentNotes: String = "") {
        self.init(
            callSign: record.callSign,
            name: record.name,
            firstName: record.firstName,
            lastName: record.lastName,
            nickname: nickname,
            street: record.street,
            city: record.city,
            county: record.county,
            state: record.state,
            persistentNotes: persistentNotes
        )
    }
}

/// Local directory of operators, stored in its own `users.sqlite` file — kept
/// **separate from the net report database** so erasing report history never
/// loses saved operators, and either can be backed up on its own.
///
/// This is the first place a call sign is looked up: QRZ is only consulted when
/// the operator isn't already known locally, which keeps repeat check-ins fast
/// and lets the app work for known stations without a network round trip.
public final class UserDatabase: SQLiteStore {
    public override init(path: String) throws {
        try super.init(path: path)
        try migrate()
    }

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS users (
                call_sign  TEXT PRIMARY KEY,
                name       TEXT NOT NULL DEFAULT '',
                first_name TEXT NOT NULL DEFAULT '',
                last_name  TEXT NOT NULL DEFAULT '',
                nickname   TEXT NOT NULL DEFAULT '',
                street     TEXT NOT NULL DEFAULT '',
                city       TEXT NOT NULL DEFAULT '',
                county     TEXT NOT NULL DEFAULT '',
                state      TEXT NOT NULL DEFAULT '',
                -- Persistent notes only. A check-in's temporary ("tonight")
                -- notes are deliberately never stored.
                notes      TEXT NOT NULL DEFAULT '',
                updated_at TEXT NOT NULL DEFAULT ''
            );
            """)
    }

    /// Call signs are stored upper-cased so lookups are case-insensitive.
    private static func normalize(_ callSign: String) -> String {
        callSign.trimmingCharacters(in: .whitespaces).uppercased()
    }

    // MARK: - Reads

    public func count() -> Int {
        (try? scalarInt("SELECT COUNT(*) FROM users;")).flatMap { $0 } ?? 0
    }

    public var isEmpty: Bool { count() == 0 }

    /// The stored operator for `callSign`, or nil when not known locally.
    public func find(callSign: String) -> UserEntry? {
        guard let stmt = try? prepare("""
            SELECT call_sign, name, first_name, last_name, nickname,
                   street, city, county, state, notes, updated_at
            FROM users WHERE call_sign = ?;
            """) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, Self.normalize(callSign))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return entry(from: stmt)
    }

    public func allEntries() throws -> [UserEntry] {
        let stmt = try prepare("""
            SELECT call_sign, name, first_name, last_name, nickname,
                   street, city, county, state, notes, updated_at
            FROM users ORDER BY call_sign ASC;
            """)
        defer { sqlite3_finalize(stmt) }
        var rows: [UserEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(entry(from: stmt)) }
        return rows
    }

    private func entry(from stmt: OpaquePointer) -> UserEntry {
        UserEntry(
            callSign: columnText(stmt, 0),
            name: columnText(stmt, 1),
            firstName: columnText(stmt, 2),
            lastName: columnText(stmt, 3),
            nickname: columnText(stmt, 4),
            street: columnText(stmt, 5),
            city: columnText(stmt, 6),
            county: columnText(stmt, 7),
            state: columnText(stmt, 8),
            persistentNotes: columnText(stmt, 9),
            updatedAt: columnText(stmt, 10)
        )
    }

    // MARK: - Writes

    private static let upsertSQL = """
        INSERT INTO users
          (call_sign, name, first_name, last_name, nickname,
           street, city, county, state, notes, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(call_sign) DO UPDATE SET
          name = excluded.name, first_name = excluded.first_name,
          last_name = excluded.last_name, nickname = excluded.nickname,
          street = excluded.street, city = excluded.city,
          county = excluded.county, state = excluded.state,
          notes = excluded.notes, updated_at = excluded.updated_at;
        """

    /// Insert or fully update an operator, including nickname and notes. Used
    /// when the operator saves the check-in form, so clearing a field sticks.
    public func save(_ entry: UserEntry, at date: Date = Date()) throws {
        let stmt = try prepare(Self.upsertSQL)
        defer { sqlite3_finalize(stmt) }
        try bindAndStep(stmt, entry, at: date)
    }

    /// Bind one entry into an already-prepared upsert statement and run it, so a
    /// bulk import can compile the SQL once instead of once per row.
    private func bindAndStep(_ stmt: OpaquePointer, _ entry: UserEntry, at date: Date) throws {
        sqlite3_reset(stmt)
        bindText(stmt, 1, Self.normalize(entry.callSign))
        bindText(stmt, 2, entry.name)
        bindText(stmt, 3, entry.firstName)
        bindText(stmt, 4, entry.lastName)
        bindText(stmt, 5, entry.nickname)
        bindText(stmt, 6, entry.street)
        bindText(stmt, 7, entry.city)
        bindText(stmt, 8, entry.county)
        bindText(stmt, 9, entry.state)
        bindText(stmt, 10, entry.persistentNotes)
        bindText(stmt, 11, SQLiteStore.timestampString(date))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    /// Cache the address fields from a QRZ lookup **without** disturbing a
    /// nickname or notes the operator already entered locally.
    public func saveDirectoryInfo(_ record: HamRecord, at date: Date = Date()) throws {
        let stmt = try prepare("""
            INSERT INTO users
              (call_sign, name, first_name, last_name, nickname,
               street, city, county, state, notes, updated_at)
            VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, '', ?)
            ON CONFLICT(call_sign) DO UPDATE SET
              name = excluded.name, first_name = excluded.first_name,
              last_name = excluded.last_name, street = excluded.street,
              city = excluded.city, county = excluded.county,
              state = excluded.state, updated_at = excluded.updated_at;
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, Self.normalize(record.callSign))
        bindText(stmt, 2, record.name)
        bindText(stmt, 3, record.firstName)
        bindText(stmt, 4, record.lastName)
        bindText(stmt, 5, record.street)
        bindText(stmt, 6, record.city)
        bindText(stmt, 7, record.county)
        bindText(stmt, 8, record.state)
        bindText(stmt, 9, SQLiteStore.timestampString(date))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    // MARK: - CSV import

    /// Import operators from a CSV. The first row must be a header; columns are
    /// matched by name (case- and separator-insensitive) so field order doesn't
    /// matter and unknown columns are ignored. Only `call_sign` is required.
    ///
    /// Recognised headers (with common aliases):
    /// `call_sign`/`callsign`/`call`, `name`, `first_name`/`fname`,
    /// `last_name`/`lname`, `nickname`/`nick`, `street`/`addr1`,
    /// `city`/`addr2`, `county`, `state`, `notes`.
    ///
    /// Returns the number of operators imported.
    @discardableResult
    public func importCSV(from url: URL, at date: Date = Date()) throws -> Int {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { return 0 }

        // Map each recognised field to its column index.
        var columns: [String: Int] = [:]
        for (index, raw) in NetDatabase.parseCSVLine(headerLine).enumerated() {
            let key = Self.canonicalHeader(raw)
            if !key.isEmpty, columns[key] == nil { columns[key] = index }
        }
        guard columns["callsign"] != nil else {
            throw DatabaseError.sql("The CSV needs a call sign column "
                                    + "(for example a header named “call_sign”).")
        }

        // Resolve the column indices once, not by hashing a String key ten
        // times per row for the whole file.
        let callIdx = columns["callsign"]
        let nameIdx = columns["name"]
        let firstIdx = columns["firstname"]
        let lastIdx = columns["lastname"]
        let nickIdx = columns["nickname"]
        let streetIdx = columns["street"]
        let cityIdx = columns["city"]
        let countyIdx = columns["county"]
        let stateIdx = columns["state"]
        let notesIdx = columns["notes"]

        func value(_ index: Int?, _ fields: [String]) -> String {
            guard let index, index < fields.count else { return "" }
            return fields[index].trimmingCharacters(in: .whitespaces)
        }

        let stmt = try prepare(Self.upsertSQL)
        defer { sqlite3_finalize(stmt) }

        try exec("BEGIN TRANSACTION;")
        var imported = 0
        do {
            for line in lines.dropFirst() {
                let fields = NetDatabase.parseCSVLine(line)
                let call = value(callIdx, fields)
                guard !call.isEmpty else { continue }

                var first = value(firstIdx, fields)
                var last = value(lastIdx, fields)
                var name = value(nameIdx, fields)
                if name.isEmpty {
                    name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                } else if first.isEmpty && last.isEmpty {
                    // Split "Theodore Marks" so nickname substitution still works.
                    let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
                    first = parts.first ?? ""
                    last = parts.count > 1 ? parts[1] : ""
                }

                try bindAndStep(stmt, UserEntry(
                    callSign: call,
                    name: name,
                    firstName: first,
                    lastName: last,
                    nickname: value(nickIdx, fields),
                    street: value(streetIdx, fields),
                    city: value(cityIdx, fields),
                    county: value(countyIdx, fields),
                    state: value(stateIdx, fields),
                    persistentNotes: value(notesIdx, fields)
                ), at: date)
                imported += 1
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        return imported
    }

    /// Normalise a header cell to a canonical field key, resolving aliases.
    private static func canonicalHeader(_ raw: String) -> String {
        let squashed = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        switch squashed {
        case "callsign", "call", "calls":         return "callsign"
        case "name", "fullname":                  return "name"
        case "firstname", "fname", "first":       return "firstname"
        case "lastname", "lname", "last", "surname": return "lastname"
        case "nickname", "nick":                  return "nickname"
        case "street", "addr1", "address", "address1": return "street"
        case "city", "addr2":                     return "city"
        case "county":                            return "county"
        case "state", "st":                       return "state"
        case "notes", "note", "persistentnotes":  return "notes"
        default:                                  return ""
        }
    }

    @discardableResult
    public func delete(callSign: String) throws -> Bool {
        let stmt = try prepare("DELETE FROM users WHERE call_sign = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, Self.normalize(callSign))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
        return sqlite3_changes(db) > 0
    }

    public func eraseAll() throws {
        try exec("DELETE FROM users;")
        try? exec("VACUUM;")
    }
}
