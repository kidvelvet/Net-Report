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

import Testing
import Foundation
import CoreText
@testable import NetReportKit

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NetReportTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
}

@Suite("Database")
struct DatabaseTests {
    private func newDB() throws -> NetDatabase {
        try NetDatabase(path: tempDir().appendingPathComponent("db.sqlite").path)
    }

    @Test func emptyStartsAtOne() throws {
        let db = try newDB()
        #expect(db.isEmpty)
        #expect(db.maxMessageNumber() == nil)
        #expect(db.nextMessageNumber() == 1)
    }

    @Test func startingNumberSubstitutesInitialNumber() throws {
        let db = try newDB()
        try db.setStartingNumber(42)
        #expect(db.nextMessageNumber() == 42)
        #expect(db.isSetupDone())

        // Once a report is logged, numbering continues from the max.
        try db.appendReport(messageNumber: 42, userCallSign: "W7SKW", receivingStation: "W1AW",
                            checkins: 10, trafficMessages: 1, pdfPath: "/tmp/a.pdf")
        #expect(db.nextMessageNumber() == 43)
        #expect(!db.isEmpty)
    }

    @Test func appendAndIncrement() throws {
        let db = try newDB()
        try db.appendReport(messageNumber: db.nextMessageNumber(), userCallSign: "W7SKW",
                            receivingStation: "W1AW", checkins: 12, trafficMessages: 1, pdfPath: "/tmp/a.pdf")
        #expect(db.nextMessageNumber() == 2)
        try db.appendReport(messageNumber: db.nextMessageNumber(), userCallSign: "W7SKW",
                            receivingStation: "W1AW", checkins: 9, trafficMessages: 0, pdfPath: "/tmp/b.pdf")
        #expect(db.nextMessageNumber() == 3)
        #expect(try db.allReports().count == 2)
    }

    @Test func importsLegacyCSV() throws {
        let db = try newDB()
        let csv = """
        message_number,timestamp,user_call_sign,receiving_station,checkins,traffic_messages,pdf_file,
        1,2025-07-02 20:00:00,W7SKW,W1AW,28,2,none,
        2,2025-07-09 20:00:00,W7SKW,W1AW,32,1,none,
        3,2025-07-11 20:00:00,W7SKW,W1AW,32,1,none,
        """
        let url = tempDir().appendingPathComponent("message_index.csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)

        let imported = try db.importCSV(from: url)
        #expect(imported == 3)                 // header skipped, 3 data rows
        #expect(db.maxMessageNumber() == 3)
        #expect(db.nextMessageNumber() == 4)
        #expect(db.isSetupDone())

        let rows = try db.allReports()
        #expect(rows.first?.checkins == 28)
        #expect(rows.first?.userCallSign == "W7SKW")
    }

    @Test func eraseClearsRowsAndConfig() throws {
        let db = try newDB()
        try db.setStartingNumber(50)
        try db.appendReport(messageNumber: 50, userCallSign: "W7SKW", receivingStation: "W1AW",
                            checkins: 5, trafficMessages: 0, pdfPath: "/tmp/a.pdf")
        #expect(!db.isEmpty)

        try db.eraseAll()
        #expect(db.isEmpty)
        #expect(!db.isSetupDone())             // setup flag reset
        #expect(db.startingNumber() == nil)    // starting number reset
        #expect(db.nextMessageNumber() == 1)
    }

    @Test func backupProducesUsableCopy() throws {
        let db = try newDB()
        try db.appendReport(messageNumber: 7, userCallSign: "W7SKW", receivingStation: "W1AW",
                            checkins: 3, trafficMessages: 1, pdfPath: "/tmp/a.pdf")
        let backupURL = tempDir().appendingPathComponent("backup.sqlite")
        try db.backup(to: backupURL)
        #expect(fileSize(backupURL) > 0)

        let restored = try NetDatabase(path: backupURL.path)
        #expect(restored.maxMessageNumber() == 7)
        #expect(try restored.allReports().count == 1)
    }

    /// A CSV carrying `Int.max` used to be stored verbatim; the `max + 1` in
    /// `nextMessageNumber()` then trapped, crashing the app on every launch
    /// afterwards (opening the data folder reads that value). The row must be
    /// rejected at import and the arithmetic must stay in range regardless.
    @Test func hugeMessageNumberCannotBrickTheDatabase() throws {
        let db = try newDB()
        let csv = """
        message_number,timestamp,user_call_sign,receiving_station,checkins,traffic_messages,pdf_file
        9223372036854775807,2026-01-01 20:00:00,W7SKW,W1AW,10,1,none
        -5,2026-01-01 20:00:00,W7SKW,W1AW,10,1,none
        7,2026-01-01 20:00:00,W7SKW,W1AW,10,1,none
        """
        let url = tempDir().appendingPathComponent("overflow.csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)

        #expect(try db.importCSV(from: url) == 1)     // only the sane row
        #expect(db.maxMessageNumber() == 7)
        #expect(db.nextMessageNumber() == 8)          // would previously trap
    }

    /// Even if an out-of-range value reaches the table by some other route,
    /// numbering must clamp instead of overflowing.
    @Test func nextMessageNumberClampsInsteadOfOverflowing() throws {
        let db = try newDB()
        try db.appendReport(messageNumber: Int.max, userCallSign: "W7SKW",
                            receivingStation: "W1AW", checkins: 1,
                            trafficMessages: 0, pdfPath: "none")
        // Must return a value, not trap.
        #expect(db.nextMessageNumber() == NetDatabase.maxAllowedMessageNumber)
    }

    @Test func startingNumberIsClamped() throws {
        let db = try newDB()
        try db.setStartingNumber(Int.max)
        #expect(db.startingNumber() == NetDatabase.maxAllowedMessageNumber)
        #expect(db.nextMessageNumber() == NetDatabase.maxAllowedMessageNumber)
    }

    /// Round-trip: back up, erase, restore from the backup.
    @Test func restoresFromBackupFile() throws {
        let db = try newDB()
        try db.appendReport(messageNumber: 12, userCallSign: "W7SKW", receivingStation: "W1AW",
                            checkins: 21, trafficMessages: 2, pdfPath: "none")
        let backupURL = tempDir().appendingPathComponent("reports-backup.sqlite")
        try db.backup(to: backupURL)

        try db.eraseAll()
        #expect(db.isEmpty)

        try db.restore(from: backupURL)
        #expect(db.reportCount() == 1)
        #expect(db.maxMessageNumber() == 12)
        #expect(db.nextMessageNumber() == 13)
        #expect(try db.allReports().first?.checkins == 21)
    }

    /// Picking the *operator* backup for the report log must fail cleanly and
    /// leave the existing data untouched, rather than wiping it.
    @Test func rejectsWrongKindOfBackupWithoutDataLoss() throws {
        let reports = try newDB()
        try reports.appendReport(messageNumber: 3, userCallSign: "W7SKW", receivingStation: "W1AW",
                                 checkins: 8, trafficMessages: 0, pdfPath: "none")

        // A perfectly valid database — of the wrong kind.
        let users = try UserDatabase(path: tempDir().appendingPathComponent("u.sqlite").path)
        let wrongURL = tempDir().appendingPathComponent("users-backup.sqlite")
        try users.backup(to: wrongURL)

        #expect(throws: DatabaseError.self) { try reports.restore(from: wrongURL) }
        #expect(reports.reportCount() == 1)          // untouched
        #expect(reports.maxMessageNumber() == 3)
    }

    @Test func rejectsNonDatabaseFileWithoutDataLoss() throws {
        let db = try newDB()
        try db.appendReport(messageNumber: 4, userCallSign: "W7SKW", receivingStation: "W1AW",
                            checkins: 5, trafficMessages: 0, pdfPath: "none")
        let junk = tempDir().appendingPathComponent("notadb.sqlite")
        try "this is not a database".write(to: junk, atomically: true, encoding: .utf8)

        #expect(throws: DatabaseError.self) { try db.restore(from: junk) }
        #expect(db.reportCount() == 1)
    }

    @Test func parsesQuotedCSVFields() {
        let fields = NetDatabase.parseCSVLine("1,\"Doe, John\",\"say \"\"hi\"\"\",x")
        #expect(fields == ["1", "Doe, John", "say \"hi\"", "x"])
    }

    /// Import a real legacy `message_index.csv` when one is supplied via the
    /// `NETREPORT_LEGACY_CSV` environment variable; skipped otherwise.
    ///
    /// Deliberately not a hard-coded path: that leaked a developer's home
    /// directory into the repository and made the test fail on every other
    /// machine. The malformed-row handling it guards is also covered
    /// synthetically by `toleratesMalformedRows` below.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETREPORT_LEGACY_CSV"] != nil))
    func importsRealLegacyFileWhenProvided() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NETREPORT_LEGACY_CSV"])
        let real = URL(fileURLWithPath: path)
        try #require(FileManager.default.fileExists(atPath: real.path))
        let db = try newDB()
        #expect(try db.importCSV(from: real) > 0)
        #expect(db.maxMessageNumber() != nil)
    }

    /// The original log had a row with a malformed timestamp (`20,00:00`), which
    /// shifts that row's columns. Import must skip or absorb it, not throw.
    @Test func toleratesMalformedRows() throws {
        let db = try newDB()
        let csv = """
        message_number,timestamp,user_call_sign,receiving_station,checkins,traffic_messages,pdf_file,
        1,2025-07-02 20:00:00,W7SKW,W1AW,28,2,none,
        5,2025-07-23 20,00:00,W7SKW,W1AW,25,1,none
        6,2025-07-30 20:00:00,W7SKW,W1AW,26,1,none,
        not-a-number,2025-08-01 20:00:00,W7SKW,W1AW,29,1,none,
        """
        let url = tempDir().appendingPathComponent("legacy.csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)

        let imported = try db.importCSV(from: url)
        #expect(imported == 3)                  // header + non-numeric row skipped
        #expect(db.maxMessageNumber() == 6)
    }
}

@Suite("Operator directory")
struct UserDatabaseTests {
    private func newDB() throws -> UserDatabase {
        try UserDatabase(path: tempDir().appendingPathComponent("users.sqlite").path)
    }

    private let theodore = HamRecord(callSign: "W1AW", name: "Theodore Marks",
                                   firstName: "Theodore", lastName: "Marks",
                                   street: "5 Rd", city: "Salem", county: "Marion", state: "OR")

    @Test func startsEmptyAndFindsNothing() throws {
        let db = try newDB()
        #expect(db.isEmpty)
        #expect(db.find(callSign: "W1AW") == nil)
    }

    @Test func savesAndFindsCaseInsensitively() throws {
        let db = try newDB()
        try db.save(UserEntry(record: theodore, nickname: "Ted", persistentNotes: "Net liaison"))

        let found = try #require(db.find(callSign: "w1aw"))
        #expect(found.callSign == "W1AW")
        #expect(found.name == "Theodore Marks")
        #expect(found.nickname == "Ted")
        #expect(found.persistentNotes == "Net liaison")
        #expect(found.city == "Salem")
        #expect(found.state == "OR")
        #expect(db.count() == 1)
    }

    /// A later QRZ refresh must not wipe the nickname/notes the operator typed.
    @Test func directoryRefreshPreservesNicknameAndNotes() throws {
        let db = try newDB()
        try db.save(UserEntry(record: theodore, nickname: "Ted", persistentNotes: "Prefers 2m"))

        var moved = theodore
        moved.city = "Eugene"
        moved.county = "Lane"
        try db.saveDirectoryInfo(moved)

        let found = try #require(db.find(callSign: "W1AW"))
        #expect(found.city == "Eugene")        // address updated
        #expect(found.county == "Lane")
        #expect(found.nickname == "Ted")      // local additions kept
        #expect(found.persistentNotes == "Prefers 2m")
    }

    /// A full save (the editor's Save) *does* apply cleared fields.
    @Test func explicitSaveOverwritesNickname() throws {
        let db = try newDB()
        try db.save(UserEntry(record: theodore, nickname: "Ted", persistentNotes: "x"))
        try db.save(UserEntry(record: theodore, nickname: "", persistentNotes: ""))
        let found = try #require(db.find(callSign: "W1AW"))
        #expect(found.nickname == "")
        #expect(found.persistentNotes == "")
    }

    /// Temporary ("tonight") notes live only on the CheckIn — the directory has
    /// no place to put them, so they can never leak into the database.
    @Test func temporaryNotesAreNotPersisted() throws {
        let db = try newDB()
        let checkIn = CheckIn(record: theodore, nickname: "Ted",
                              persistentNotes: "Prefers 2m",
                              temporaryNotes: "Has traffic tonight")
        // The app stores only what UserEntry carries.
        try db.save(UserEntry(record: theodore, nickname: checkIn.nickname,
                              persistentNotes: checkIn.persistentNotes))

        let found = try #require(db.find(callSign: "W1AW"))
        #expect(found.persistentNotes == "Prefers 2m")
        // Reloading a later net starts with no temporary notes.
        let reloaded = CheckIn(record: found.record, nickname: found.nickname,
                               persistentNotes: found.persistentNotes)
        #expect(reloaded.temporaryNotes == "")
        #expect(reloaded.persistentNotes == "Prefers 2m")
    }

    @Test func importsOperatorCSVByHeaderName() throws {
        let db = try newDB()
        // Deliberately out of order, mixed aliases, extra unknown column.
        let csv = """
        Nickname,Call Sign,City,County,State,Name,Notes,Rig
        Ted,W1AW,Salem,Marion,OR,Theodore Marks,NTS liaison,IC-7300
        Annie,k7abc,Bend,Deschutes,OR,Ann Baker,,FT-991
        """
        let url = tempDir().appendingPathComponent("ops.csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)

        #expect(try db.importCSV(from: url) == 2)
        let ted = try #require(db.find(callSign: "W1AW"))
        #expect(ted.name == "Theodore Marks")
        #expect(ted.nickname == "Ted")
        #expect(ted.county == "Marion")
        #expect(ted.persistentNotes == "NTS liaison")
        // Name gets split so nickname substitution works on imported rows.
        #expect(ted.firstName == "Theodore")
        #expect(ted.lastName == "Marks")
        #expect(ted.record.displayName(nickname: "Ted") == "Ted Marks")
        // Lower-case call signs are normalised.
        #expect(db.find(callSign: "K7ABC")?.city == "Bend")
    }

    @Test func importsOperatorCSVWithSeparateNameColumns() throws {
        let db = try newDB()
        let csv = """
        callsign,fname,lname,city
        N7XYZ,Robert,Longsurname,Hood River
        """
        let url = tempDir().appendingPathComponent("ops2.csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)

        #expect(try db.importCSV(from: url) == 1)
        let entry = try #require(db.find(callSign: "N7XYZ"))
        #expect(entry.firstName == "Robert")
        #expect(entry.lastName == "Longsurname")
        #expect(entry.name == "Robert Longsurname")   // composed
    }

    @Test func operatorCSVWithoutCallSignColumnThrows() throws {
        let db = try newDB()
        let url = tempDir().appendingPathComponent("bad.csv")
        try "name,city\nAnn Baker,Bend".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: DatabaseError.self) { try db.importCSV(from: url) }
        #expect(db.isEmpty)
    }

    @Test func operatorCSVSkipsRowsWithoutCallSign() throws {
        let db = try newDB()
        let csv = """
        call_sign,name
        W1AW,Theodore Marks
        ,Nobody
        K7ABC,Ann Baker
        """
        let url = tempDir().appendingPathComponent("gaps.csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        #expect(try db.importCSV(from: url) == 2)
        #expect(db.count() == 2)
    }

    /// The operator directory restores from its own backup, nicknames and
    /// persistent notes intact.
    @Test func restoresDirectoryFromBackup() throws {
        let db = try newDB()
        try db.save(UserEntry(record: theodore, nickname: "Ted", persistentNotes: "NTS liaison"))
        let backupURL = tempDir().appendingPathComponent("users-backup.sqlite")
        try db.backup(to: backupURL)

        try db.eraseAll()
        #expect(db.isEmpty)

        try db.restore(from: backupURL)
        let found = try #require(db.find(callSign: "W1AW"))
        #expect(found.nickname == "Ted")
        #expect(found.persistentNotes == "NTS liaison")
        #expect(found.lastName == "Marks")
    }

    @Test func deleteRemovesEntry() throws {
        let db = try newDB()
        try db.save(UserEntry(record: theodore))
        #expect(try db.delete(callSign: "W1AW") == true)
        #expect(db.find(callSign: "W1AW") == nil)
        #expect(try db.delete(callSign: "W1AW") == false)
    }

    /// A forced QRZ refresh fills in missing address data but must leave the
    /// operator's nickname and persistent notes alone.
    @Test func forcedRefreshFillsGapsWithoutLosingLocalEdits() throws {
        let db = try newDB()
        // A sparse local record: nickname + notes, but no address details.
        try db.save(UserEntry(callSign: "W1AW", name: "Theodore Marks",
                              nickname: "Ted", persistentNotes: "NTS liaison"))
        var found = try #require(db.find(callSign: "W1AW"))
        #expect(found.city.isEmpty)
        #expect(found.county.isEmpty)

        // Forced QRZ refresh path.
        try db.saveDirectoryInfo(theodore)

        found = try #require(db.find(callSign: "W1AW"))
        #expect(found.city == "Salem")            // gap filled
        #expect(found.county == "Marion")
        #expect(found.state == "OR")
        #expect(found.firstName == "Theodore")      // enables nickname substitution
        #expect(found.lastName == "Marks")
        #expect(found.nickname == "Ted")         // preserved
        #expect(found.persistentNotes == "NTS liaison")
    }

    @Test func entryRoundTripsToHamRecord() throws {
        let db = try newDB()
        try db.save(UserEntry(record: theodore, nickname: "Ted"))
        let record = try #require(db.find(callSign: "W1AW")).record
        // First/last survive, so nickname substitution still works off the directory.
        #expect(record.displayName(nickname: "Ted") == "Ted Marks")
        #expect(record.state == "OR")
    }

    @Test func backupAndEraseAreIndependent() throws {
        let db = try newDB()
        try db.save(UserEntry(record: theodore, nickname: "Ted"))
        let backupURL = tempDir().appendingPathComponent("users-backup.sqlite")
        try db.backup(to: backupURL)

        try db.eraseAll()
        #expect(db.isEmpty)

        let restored = try UserDatabase(path: backupURL.path)
        #expect(restored.find(callSign: "W1AW")?.nickname == "Ted")
    }

    /// The two databases are separate files: erasing reports keeps operators.
    @Test func reportEraseLeavesOperatorDirectoryIntact() throws {
        let folder = tempDir()
        let reports = try NetDatabase(path: folder.appendingPathComponent("netreport.sqlite").path)
        let users = try UserDatabase(path: folder.appendingPathComponent("users.sqlite").path)

        try users.save(UserEntry(record: theodore, nickname: "Ted"))
        try reports.appendReport(messageNumber: 1, userCallSign: "W7SKW", receivingStation: "W1AW",
                                 checkins: 4, trafficMessages: 0, pdfPath: "/tmp/a.pdf")

        try reports.eraseAll()
        #expect(reports.isEmpty)
        #expect(users.find(callSign: "W1AW")?.nickname == "Ted")
    }
}

@Suite("NTS form")
struct NTSFormTests {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test func fieldsComputed() {
        let user = HamRecord(callSign: "W7SKW", name: "Operator", street: "1 St",
                             city: "Portland", county: "Multnomah", state: "OR")
        let form = NetReportBuilder.makeNTSForm(
            messageNumber: 17, userCallSign: "W7SKW", userRecord: user,
            receivingStation: "W1AW", receivingRecord: nil,
            totalCheckins: 34, trafficMessages: 1, date: date(2026, 5, 17, 20, 21))

        #expect(form.line1 == "Oregon D1 Net Report May")
        #expect(form.line2 == "17 checkins 34 traffic 1")
        #expect(form.placeOrigin == "Portland, OR")
        #expect(form.dateFiled == "May 17")
        #expect(form.timeFiled == "2021")
        #expect(form.toName == "W1AW")
    }

    @Test func receivingRecordExpandsToName() {
        let rx = HamRecord(callSign: "W1AW", name: "Net Liaison", street: "5 Rd",
                           city: "Salem", county: "Marion", state: "OR")
        let form = NetReportBuilder.makeNTSForm(
            messageNumber: 1, userCallSign: "W7SKW", userRecord: nil,
            receivingStation: "W1AW", receivingRecord: rx,
            totalCheckins: 1, trafficMessages: 0, date: date(2026, 1, 1))
        #expect(form.toName == "W1AW - Net Liaison")
        #expect(form.toCityState == "Salem, OR")
        #expect(form.placeOrigin == "Unknown, Unknown")
    }

    /// W1AW "Theodore Marks" with nickname "Ted" prints as "Ted Marks".
    @Test func receivingNicknameReplacesFirstName() {
        let rx = HamRecord(callSign: "W1AW", name: "Theodore Marks",
                           firstName: "Theodore", lastName: "Marks",
                           street: "5 Rd", city: "Salem", county: "Marion", state: "OR")
        let form = NetReportBuilder.makeNTSForm(
            messageNumber: 1, userCallSign: "W7SKW", userRecord: nil,
            receivingStation: "W1AW", receivingRecord: rx, receivingNickname: "Ted",
            totalCheckins: 1, trafficMessages: 0, date: date(2026, 1, 1))
        #expect(form.toName == "W1AW - Ted Marks")
    }

    @Test func blankReceivingNicknameKeepsFullName() {
        let rx = HamRecord(callSign: "W1AW", name: "Theodore Marks",
                           firstName: "Theodore", lastName: "Marks",
                           street: "5 Rd", city: "Salem", county: "Marion", state: "OR")
        let form = NetReportBuilder.makeNTSForm(
            messageNumber: 1, userCallSign: "W7SKW", userRecord: nil,
            receivingStation: "W1AW", receivingRecord: rx, receivingNickname: "   ",
            totalCheckins: 1, trafficMessages: 0, date: date(2026, 1, 1))
        #expect(form.toName == "W1AW - Theodore Marks")
    }

    @Test func nicknameUsedEvenWithoutQRZRecord() {
        let form = NetReportBuilder.makeNTSForm(
            messageNumber: 1, userCallSign: "W7SKW", userRecord: nil,
            receivingStation: "W1AW", receivingRecord: nil, receivingNickname: "Ted",
            totalCheckins: 1, trafficMessages: 0, date: date(2026, 1, 1))
        #expect(form.toName == "W1AW - Ted")
    }
}

@Suite("Name display")
struct NameDisplayTests {
    private let theodore = HamRecord(callSign: "W1AW", name: "Theodore Marks",
                                   firstName: "Theodore", lastName: "Marks",
                                   street: "5 Rd", city: "Salem", county: "Marion", state: "OR")

    @Test func substitutesGivenName() {
        #expect(theodore.displayName(nickname: "Ted") == "Ted Marks")
    }

    @Test func emptyNicknameKeepsFullName() {
        #expect(theodore.displayName(nickname: "") == "Theodore Marks")
        #expect(theodore.displayName(nickname: "  ") == "Theodore Marks")
    }

    @Test func nicknameAloneWhenSurnameUnknown() {
        let noSurname = HamRecord(callSign: "K7ABC", name: "Unknown",
                                  street: "", city: "", county: "", state: "")
        #expect(noSurname.displayName(nickname: "Sam") == "Sam")
    }
}

@Suite("Filenames")
struct FilenameTests {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test func timestampedNames() {
        let d = date(2026, 2, 21, 20, 0, 27)
        #expect(NetReportBuilder.timestampToken(for: d) == "20260221_200027")
        #expect(NetReportBuilder.checkinListFilename(for: d) == "checkin_list_20260221_200027.pdf")
        #expect(NetReportBuilder.netReportFilename(for: d) == "net_report_20260221_200027.pdf")
    }
}

@Suite("Check-in rows")
struct CheckInRowTests {
    private let full = CheckIn(
        callSign: "K7ABC", name: "Ann Baker", nickname: "Annie",
        city: "Bend", county: "Deschutes", state: "OR",
        persistentNotes: "Prefers 2m", temporaryNotes: "Has traffic for Salem")

    @Test func tableRowCombinesBothNotes() {
        #expect(full.tableRow == ["K7ABC", "Ann Baker", "Annie", "Bend", "Deschutes",
                                  "Prefers 2m; Has traffic for Salem"])
    }

    @Test func combinedNotesSkipsEmptyHalves() {
        var onlyPersistent = full; onlyPersistent.temporaryNotes = ""
        #expect(onlyPersistent.combinedNotes == "Prefers 2m")

        var onlyTemporary = full; onlyTemporary.persistentNotes = ""
        #expect(onlyTemporary.combinedNotes == "Has traffic for Salem")

        var neither = full; neither.persistentNotes = ""; neither.temporaryNotes = ""
        #expect(neither.combinedNotes == "")
        #expect(neither.tableRow.last == "")
    }

    @Test func logLineLabelsBothKindsOfNote() {
        let line = full.logLine
        #expect(line.contains("K7ABC — Ann Baker"))
        #expect(line.contains("(Annie)"))
        #expect(line.contains("Bend, Deschutes"))
        #expect(line.contains("Notes: Prefers 2m"))
        #expect(line.contains("Tonight: Has traffic for Salem"))
    }

    @Test func logLineOmitsEmptyNotes() {
        let c = CheckIn(callSign: "K7ABC", name: "Ann Baker",
                        city: "Bend", county: "Deschutes")
        #expect(!c.logLine.contains("Notes:"))
        #expect(!c.logLine.contains("Tonight:"))
        #expect(!c.logLine.contains("("))
        #expect(!c.logLine.contains("ANNOUNCEMENT"))
    }

    @Test func announcementMarkedInLogAndDefaultsOff() {
        #expect(full.hasAnnouncement == false)
        #expect(full.announcementCompleted == false)
        var flagged = full
        flagged.hasAnnouncement = true
        #expect(flagged.logLine.contains("★ ANNOUNCEMENT"))
        // The flag is per-net presentation only; it doesn't alter report cells.
        #expect(flagged.tableRow == full.tableRow)
    }

    @Test func completedAnnouncementReadsAsDone() {
        var flagged = full
        flagged.hasAnnouncement = true
        flagged.announcementCompleted = true
        #expect(flagged.logLine.contains("✓ ANNOUNCEMENT (read)"))
        #expect(!flagged.logLine.contains("★"))
        // Completion is a reading aid — the report row is unaffected.
        #expect(flagged.tableRow == full.tableRow)
    }

    /// The announcement flag is a per-net concern, so the directory entry built
    /// from a check-in carries no trace of it.
    @Test func announcementIsNotPartOfDirectoryEntry() {
        var flagged = full
        flagged.hasAnnouncement = true
        let entry = UserEntry(callSign: flagged.callSign, name: flagged.name,
                              nickname: flagged.nickname,
                              persistentNotes: flagged.persistentNotes)
        let rebuilt = CheckIn(record: entry.record, nickname: entry.nickname,
                              persistentNotes: entry.persistentNotes)
        #expect(rebuilt.hasAnnouncement == false)
        #expect(rebuilt.announcementCompleted == false)
    }

    /// Counting pending announcements, as the badge and header do.
    @Test func pendingCountIgnoresCompletedOnes() {
        var a = full; a.hasAnnouncement = true
        var b = full; b.hasAnnouncement = true; b.announcementCompleted = true
        let c = full   // no announcement at all
        let all = [a, b, c]

        let announcements = all.filter(\.hasAnnouncement)
        #expect(announcements.count == 2)
        #expect(announcements.count { !$0.announcementCompleted } == 1)
    }
}

@Suite("Report generation")
struct ReportGenerationTests {
    private let checkIns = [
        CheckIn(callSign: "W7SKW", name: "Operator Name", nickname: "Op",
                city: "Portland", county: "Multnomah", state: "OR", persistentNotes: "Net control"),
        CheckIn(callSign: "K7ABC", name: "Some Very Long Name That Wraps",
                city: "Beaverton", county: "Washington", state: "OR",
                persistentNotes: "Checking in mobile", temporaryNotes: "has traffic for the Salem area"),
    ]

    private func date(_ s: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 2; c.day = 21; c.hour = 20; c.minute = 0; c.second = s
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func generate(in out: URL, db: NetDatabase, at second: Int) throws -> NetReportResult {
        try NetReportBuilder.generate(
            userCallSign: "W7SKW", userRecord: nil,
            receivingStation: "W1AW", receivingRecord: nil,
            checkIns: checkIns, trafficMessages: 1,
            outputDirectory: out, database: db, date: date(second))
    }

    @Test func writesSplitPDFsAndLogsToDatabase() throws {
        let out = tempDir()
        let db = try NetDatabase(path: out.appendingPathComponent("db.sqlite").path)
        let result = try generate(in: out, db: db, at: 27)

        #expect(result.checkinListURL.deletingLastPathComponent().lastPathComponent == "Checkin List")
        #expect(result.netReportURL.deletingLastPathComponent().lastPathComponent == "Net Reports")
        #expect(fileSize(result.checkinListURL) > 1000)
        #expect(fileSize(result.netReportURL) > 1000)

        let rows = try db.allReports()
        #expect(rows.count == 1)
        #expect(rows.first?.messageNumber == result.messageNumber)
        #expect(rows.first?.pdfFile == result.netReportURL.path)
    }

    @Test func newReportNeverOverwritesPrevious() throws {
        let out = tempDir()
        let db = try NetDatabase(path: out.appendingPathComponent("db.sqlite").path)
        let first = try generate(in: out, db: db, at: 27)
        let second = try generate(in: out, db: db, at: 45)

        #expect(second.netReportURL != first.netReportURL)
        #expect(second.checkinListURL != first.checkinListURL)
        #expect(FileManager.default.fileExists(atPath: first.netReportURL.path))
        #expect(FileManager.default.fileExists(atPath: first.checkinListURL.path))
        #expect(second.messageNumber == first.messageNumber + 1)
    }

    @Test func honoursStartingNumber() throws {
        let out = tempDir()
        let db = try NetDatabase(path: out.appendingPathComponent("db.sqlite").path)
        try db.setStartingNumber(100)
        let result = try generate(in: out, db: db, at: 27)
        #expect(result.messageNumber == 100)
    }
}

@Suite("PDF text wrapping")
struct WrapTests {
    /// The wrapping algorithm exactly as it was before the single-measurement
    /// fast path was added. The optimisation is only worth having if it is a
    /// true equivalence, so it is checked against this reference.
    private func referenceWrap(_ text: String, font: CTFont, maxWidth: CGFloat) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [""] }

        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if RadiogramPDF.textWidth(candidate, font: font) <= maxWidth || current.isEmpty {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    @Test func fastPathMatchesOriginalAlgorithm() {
        let font = RadiogramPDF.regular(9)
        let corpus = [
            "", " ", "   ",
            "W7SKW", "Multnomah", "Hood River",
            "Theodore Marks", "Ann Baker",
            "Net control",
            "NTS liaison; took 1 message tonight and will relay",
            "Mobile tonight, weak signal here on the north side of the valley",
            "Robert Verylongsurnamehere",
            "Supercalifragilisticexpialidociousandthensome",
            "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z",
            "one  two   three",     // repeated separators
            "trailing space ",
        ]
        // Includes the real column widths (minus padding) plus tighter ones.
        let widths: [CGFloat] = [8, 20, 62, 72, 102, 122, 300]

        for text in corpus {
            for maxWidth in widths {
                let optimised = RadiogramPDF.wrap(text, font: font, maxWidth: maxWidth)
                let reference = referenceWrap(text, font: font, maxWidth: maxWidth)
                #expect(optimised == reference,
                        "wrap mismatch for \"\(text)\" at width \(maxWidth): \(optimised) vs \(reference)")
            }
        }
    }

    /// The point of the fast path: text that fits is not measured word by word.
    @Test func singleLineTextIsReturnedWhole() {
        let font = RadiogramPDF.regular(9)
        #expect(RadiogramPDF.wrap("Net control", font: font, maxWidth: 300) == ["Net control"])
        #expect(RadiogramPDF.wrap("", font: font, maxWidth: 300) == [""])
        #expect(RadiogramPDF.wrap("   ", font: font, maxWidth: 300) == [""])
    }
}

@Suite("QRZ XML parsing")
struct QRZParserTests {
    @Test func extractsSessionAndCallsignFields() {
        let xml = """
        <?xml version="1.0"?>
        <QRZDatabase xmlns="http://xmldata.qrz.com">
          <Session><Key>abc123</Key></Session>
          <Callsign>
            <call>W7SKW</call><fname>Test</fname><name>Operator</name>
            <addr1>1 Main</addr1><addr2>Portland</addr2>
            <county>Multnomah</county><state>OR</state>
          </Callsign>
        </QRZDatabase>
        """
        let values = QRZResponseParser().parse(Data(xml.utf8))
        #expect(values["Key"] == "abc123")
        #expect(values["call"] == "W7SKW")
        #expect(values["fname"] == "Test")
        #expect(values["name"] == "Operator")
        #expect(values["state"] == "OR")
        #expect(values["__hasCallsign"] == "1")
    }

    /// QRZ splits the name across <fname> (given) and <name> (surname); both are
    /// needed so a nickname can replace only the given name.
    @Test func credentialsComeFromEnvironmentOnly() {
        // No baked-in account: env vars are the only non-Keychain source.
        let creds = QRZCredentials(username: "K7XYZ", password: "secret")
        #expect(creds.username == "K7XYZ")
        #expect(creds.password == "secret")
    }

    /// A spoofed or compromised endpoint must not be able to use an external
    /// entity to read a local file. The parser refuses external entities, so
    /// the reference expands to nothing rather than to the file's contents.
    @Test func rejectsExternalEntities() throws {
        let secret = FileManager.default.temporaryDirectory
            .appendingPathComponent("xxe-\(UUID().uuidString).txt")
        try "TOP-SECRET-CONTENTS".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }

        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE QRZDatabase [
          <!ENTITY xxe SYSTEM "file://\(secret.path)">
        ]>
        <QRZDatabase xmlns="http://xmldata.qrz.com">
          <Session><Key>abc123</Key></Session>
          <Callsign><call>W7SKW</call><fname>&xxe;</fname><name>Operator</name></Callsign>
        </QRZDatabase>
        """
        let values = QRZResponseParser().parse(Data(xml.utf8))
        #expect(values["fname"]?.contains("TOP-SECRET-CONTENTS") != true)
        #expect(values["call"] == nil || values["call"] == "W7SKW")
    }

    /// Deeply nested internal entities ("billion laughs") must not hang or
    /// exhaust memory — the parser should bail out rather than expand them.
    @Test func survivesEntityExpansionBomb() {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE QRZDatabase [
          <!ENTITY a "aaaaaaaaaa">
          <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
          <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
          <!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">
          <!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;">
        ]>
        <QRZDatabase><Session><Key>&e;</Key></Session></QRZDatabase>
        """
        // Must return (not hang); the key is either absent or bounded.
        let values = QRZResponseParser().parse(Data(xml.utf8))
        #expect((values["Key"]?.count ?? 0) < 1_000_000)
    }

    @Test func reportsLoginError() {
        let xml = """
        <QRZDatabase xmlns="http://xmldata.qrz.com">
          <Session><Error>Username/password incorrect</Error></Session>
        </QRZDatabase>
        """
        let values = QRZResponseParser().parse(Data(xml.utf8))
        #expect(values["Key"] == nil)
        #expect(values["Error"] == "Username/password incorrect")
        #expect(values["__hasCallsign"] == nil)
    }
}
