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
import Observation
import AppKit
import UniformTypeIdentifiers
import NetReportKit

/// Drives the net-control workflow: operator setup, QRZ check-ins, report
/// generation, and the report database. GUI equivalent of `main()` in the
/// original `ham_lookup.py`, with the CSV message index replaced by a SQLite
/// database that can live locally or in a shared/synced data folder.
@MainActor
@Observable
final class NetSession {

    // MARK: Operator
    var operatorCallSign = ""
    private(set) var operatorRecord: HamRecord?
    private(set) var netStarted = false

    // MARK: Check-ins
    private(set) var checkIns: [CheckIn] = []

    // MARK: Report inputs
    var receivingStation = ""
    /// Optional nickname for the receiving operator: replaces their given name on
    /// the radiogram ("Theodore Marks" + "Ted" → "Ted Marks").
    var receivingNickname = ""
    var trafficMessages = 1

    // MARK: Output / status
    private(set) var outputDirectory: URL
    private(set) var log: [String] = []
    private(set) var isBusy = false
    var errorMessage: String?
    private(set) var lastResult: NetReportResult?

    // MARK: Check-in editor (secondary window)
    /// Non-nil while the add/edit check-in window is open.
    var editorTarget: EditorTarget?

    enum EditorTarget: Identifiable, Equatable {
        case add
        case edit(CheckIn)

        var id: String {
            switch self {
            case .add:            return "add"
            case .edit(let c):    return c.id.uuidString
            }
        }

        var existing: CheckIn? {
            if case .edit(let c) = self { return c }
            return nil
        }
    }

    // MARK: Database
    private(set) var database: NetDatabase
    /// Local operator directory — a *separate* database from the report log.
    private(set) var userDatabase: UserDatabase
    /// Non-nil when the database could not be opened at the chosen location and a
    /// temporary in-memory database is in use.
    private(set) var databaseError: String?
    /// True when the database is empty and first-run setup hasn't been completed.
    private(set) var needsDatabaseSetup = false

    // MARK: QRZ account
    /// Signed-in QRZ user name, for display. Nil when not signed in.
    private(set) var qrzUsername: String?
    /// True while the QRZ sign-in sheet should be shown.
    var needsCredentials = false
    private(set) var credentialsAreSaved = false

    // MARK: First-run setup
    /// True until the setup wizard has been completed on *this* machine. Stored
    /// per-machine (not in the database) so a new computer pointed at a shared
    /// data folder still gets asked where that folder is.
    private(set) var needsFirstRunSetup = false

    private static let dataFolderKey = "dataFolder"
    private static let setupCompleteKey = "hasCompletedFirstRunSetup"
    private var client: QRZClient?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let defaultFolder = docs.appendingPathComponent("Net Report", isDirectory: true)
        let folder = UserDefaults.standard.url(forKey: Self.dataFolderKey) ?? defaultFolder
        outputDirectory = folder

        // Start on in-memory DBs, then open the real ones. `try!` rather than
        // `(try?)!` so that if this ever did fail the crash report names the
        // SQLite error instead of an opaque "unexpectedly found nil". Opening
        // an in-memory database touches no filesystem, so there is no
        // attacker-influenced input that can make it fail.
        database = try! NetDatabase(path: ":memory:")
        userDatabase = try! UserDatabase(path: ":memory:")
        openDatabase(at: folder)
        restoreCredentials()

        needsFirstRunSetup = !UserDefaults.standard.bool(forKey: Self.setupCompleteKey)
        if needsFirstRunSetup {
            // The wizard covers sign-in and database setup; suppress the
            // one-off sheets that would otherwise compete with it.
            needsCredentials = false
            needsDatabaseSetup = false
        }
    }

    // MARK: - First-run setup wizard

    /// Row counts and the next message number, shown on the wizard and in the
    /// database manager.
    ///
    /// Cached rather than queried on demand: SwiftUI reads these many times per
    /// render, and as stored properties `@Observable` can also track them, so
    /// the views actually refresh after an import or erase.
    private(set) var operatorCount = 0
    private(set) var reportCount = 0
    private(set) var nextMessageNumber = 1
    var foundExistingData: Bool { operatorCount > 0 || reportCount > 0 }

    /// Re-read the cached operator count. Use after directory-only changes so we
    /// don't scan the report log for nothing.
    private func refreshOperatorCount() {
        operatorCount = userDatabase.count()
    }

    /// Every write to the operator directory goes through these two helpers, so
    /// the cached `operatorCount` can never be left stale by a new call site.
    private func storeDirectoryInfo(_ record: HamRecord) {
        try? userDatabase.saveDirectoryInfo(record)
        refreshOperatorCount()
    }

    /// `isNew: false` skips the recount: `save` upserts on the call sign, so if
    /// the caller already established the row exists, the write is an UPDATE and
    /// the count cannot have changed. That spares a COUNT(*) per check-in.
    private func storeOperator(_ entry: UserEntry, isNew: Bool = true) throws {
        try userDatabase.save(entry)
        if isNew { refreshOperatorCount() }
    }

    /// Re-read the cached report figures after report-log changes.
    private func refreshReportCounts() {
        reportCount = database.reportCount()
        nextMessageNumber = database.nextMessageNumber()
    }

    /// Re-read every cached count. Use when both databases may have changed
    /// (opening a data folder, finishing setup).
    private func refreshCounts() {
        refreshOperatorCount()
        refreshReportCounts()
    }

    /// Finish the wizard and go to the main window.
    func completeFirstRunSetup() {
        UserDefaults.standard.set(true, forKey: Self.setupCompleteKey)
        try? database.markSetupDone()
        needsFirstRunSetup = false
        refreshSetupState()
        append(log: "Setup complete. Data folder: \(outputDirectory.path)")
    }

    /// Re-run the wizard on demand (File ▸ Run Setup Again…).
    func restartFirstRunSetup() {
        needsFirstRunSetup = true
    }

    /// Import operators from a CSV chosen by the user. Returns the count.
    @discardableResult
    func importUserCSV(from url: URL) -> Int? {
        do {
            let count = try userDatabase.importCSV(from: url)
            append(log: "Imported \(count) operator\(count == 1 ? "" : "s") from \(url.lastPathComponent).")
            refreshOperatorCount()
            return count
        } catch {
            errorMessage = "Operator import failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Panel + import for the operator directory CSV.
    @discardableResult
    func importUserCSVInteractive() -> Int? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a CSV of operators to import. "
            + "It needs a header row including a call sign column."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return importUserCSV(from: url)
    }

    /// Panel + restore for a backed-up operator directory (`.sqlite`).
    /// Returns the number of operators after restoring, or nil if cancelled.
    @discardableResult
    func importUserBackupInteractive() -> Int? {
        guard let url = chooseBackupFile(kind: .operators) else { return nil }
        do {
            try userDatabase.restore(from: url)
            refreshOperatorCount()
            append(log: "Restored \(operatorCount) operator"
                   + "\(operatorCount == 1 ? "" : "s") from \(url.lastPathComponent).")
            return operatorCount
        } catch {
            errorMessage = "Could not import that backup: \(error.localizedDescription)"
            return nil
        }
    }

    /// Panel + restore for a backed-up report log (`.sqlite`).
    @discardableResult
    func importReportBackupInteractive() -> Int? {
        guard let url = chooseBackupFile(kind: .reports) else { return nil }
        do {
            try database.restore(from: url)
            refreshSetupState()
            append(log: "Restored \(reportCount) net report"
                   + "\(reportCount == 1 ? "" : "s") from \(url.lastPathComponent).")
            return reportCount
        } catch {
            errorMessage = "Could not import that backup: \(error.localizedDescription)"
            return nil
        }
    }

    private func chooseBackupFile(kind: DatabaseKind) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a backed-up \(kind.rawValue.lowercased()) database "
            + "(.sqlite). Its contents will replace what is here now."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Panel + import for the net report log CSV. Returns rows imported.
    @discardableResult
    func importReportCSVInteractive() -> Int? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a message_index.csv (original format) to import."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let count = try database.importCSV(from: url)
            append(log: "Imported \(count) net report\(count == 1 ? "" : "s") from \(url.lastPathComponent).")
            refreshSetupState()
            return count
        } catch {
            errorMessage = "Report import failed: \(error.localizedDescription)"
            return nil
        }
    }

    var totalCheckins: Int { checkIns.count }

    var isSignedIn: Bool { client != nil }

    // MARK: - QRZ credentials

    /// Sign in from the Keychain (or `QRZ_USERNAME`/`QRZ_PASSWORD`) if possible;
    /// otherwise ask the operator for their QRZ login.
    private func restoreCredentials() {
        if let saved = KeychainStore.load() {
            client = QRZClient(credentials: saved)
            qrzUsername = saved.username
            credentialsAreSaved = true
        } else if let env = QRZCredentials.fromEnvironment() {
            client = QRZClient(credentials: env)
            qrzUsername = env.username
        } else {
            needsCredentials = true
        }
    }

    /// Verify a QRZ login and adopt it for this session, optionally saving it to
    /// the Keychain. Returns true when QRZ accepted the credentials.
    func signIn(username: String, password: String, saveToKeychain: Bool) async -> Bool {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !password.isEmpty else {
            errorMessage = "Enter both your QRZ user name and password."
            return false
        }

        isBusy = true
        defer { isBusy = false }

        let credentials = QRZCredentials(username: user, password: password)
        let candidate = QRZClient(credentials: credentials)
        do {
            try await candidate.login()
        } catch {
            errorMessage = "QRZ sign-in failed: \(error.localizedDescription)"
            return false
        }

        client = candidate
        qrzUsername = user
        needsCredentials = false
        credentialsAreSaved = false

        if saveToKeychain {
            do {
                try KeychainStore.save(credentials)
                credentialsAreSaved = true
                append(log: "Signed in to QRZ as \(user); credentials saved to your Keychain.")
            } catch {
                errorMessage = "Signed in, but saving to the Keychain failed: "
                    + error.localizedDescription
            }
        } else {
            append(log: "Signed in to QRZ as \(user) for this session.")
        }
        return true
    }

    /// Show the QRZ sign-in sheet (File ▸ QRZ Account…).
    func presentCredentialsPrompt() {
        needsCredentials = true
    }

    /// Dismiss the sign-in sheet without signing in.
    func dismissCredentialsPrompt() {
        needsCredentials = false
    }

    /// Forget the stored QRZ login and sign out of this session.
    func signOutAndForgetCredentials() {
        KeychainStore.remove()
        client = nil
        qrzUsername = nil
        credentialsAreSaved = false
        needsCredentials = true
        append(log: "Signed out of QRZ; saved credentials removed from the Keychain.")
    }

    // MARK: - Database lifecycle

    private func openDatabase(at folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dbURL = folder.appendingPathComponent("netreport.sqlite")
        let usersURL = folder.appendingPathComponent("users.sqlite")
        do {
            database = try NetDatabase(path: dbURL.path)
            userDatabase = try UserDatabase(path: usersURL.path)
            databaseError = nil
        } catch {
            databaseError = "Could not open the databases in \(folder.path): "
                + "\(error.localizedDescription) Using temporary in-memory databases — "
                + "changes will not be saved."
            database = (try? NetDatabase(path: ":memory:")) ?? database
            userDatabase = (try? UserDatabase(path: ":memory:")) ?? userDatabase
        }
        refreshSetupState()
    }

    /// Re-read everything derived from the databases. Called after any change.
    private func refreshSetupState() {
        refreshCounts()
        // Reuse the count just taken instead of running another COUNT(*).
        needsDatabaseSetup = reportCount == 0 && !database.isSetupDone()
    }

    /// Point the app at a different data folder (local, synced, or on a network
    /// share) and open the database there.
    func chooseDataFolder(url: URL) {
        outputDirectory = url
        UserDefaults.standard.set(url, forKey: Self.dataFolderKey)
        openDatabase(at: url)
        append(log: "Data folder set to \(url.path).")
    }

    // MARK: - First-run setup

    func importCSV(from url: URL) {
        do {
            let count = try database.importCSV(from: url)
            append(log: "Imported \(count) report\(count == 1 ? "" : "s") from \(url.lastPathComponent).")
            refreshSetupState()
        } catch {
            errorMessage = "CSV import failed: \(error.localizedDescription)"
        }
    }

    func applyStartingNumber(_ number: Int) {
        do {
            try database.setStartingNumber(number)
            append(log: "Starting message number set to \(number).")
            refreshSetupState()
        } catch {
            errorMessage = "Could not set starting number: \(error.localizedDescription)"
        }
    }

    /// Dismiss setup without importing or choosing a number (defaults to 1).
    func skipSetup() {
        try? database.markSetupDone()
        refreshSetupState()
    }

    // MARK: - Operator setup

    func startNet() async {
        let call = operatorCallSign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else {
            errorMessage = "Enter your call sign first."
            return
        }
        operatorCallSign = call
        isBusy = true
        defer { isBusy = false }

        // Local directory first, then QRZ — same precedence as the check-in
        // editor. A known operator starts the net with no network at all: no
        // login, no lookup. `lookup` authenticates on its own when needed, so
        // there is no separate `login()` round trip here either.
        var record: HamRecord?
        var nickname = ""
        if let local = userDatabase.find(callSign: call) {
            record = local.record
            nickname = local.nickname
        } else if let client {
            record = (try? await client.lookup(callSign: call)) ?? nil
            if let record {
                storeDirectoryInfo(record)
            } else {
                errorMessage = "Couldn't look up \(call) on QRZ — starting the net "
                    + "anyway; edit your entry to fill in the details."
            }
        } else {
            // No QRZ account (the setup wizard allows skipping it): start the
            // net anyway and let the operator type their own details.
            errorMessage = "Not signed in to QRZ — starting the net with placeholder "
                + "details. Edit your check-in to fill them in."
        }
        operatorRecord = record
        let seed: CheckIn = record.map { CheckIn(record: $0, nickname: nickname) }
            ?? CheckIn(callSign: call, name: "Unknown", city: "Unknown", county: "Unknown")
        checkIns = [seed]
        netStarted = true
        append(log: "Net started. Operator \(call) checked in.")
    }

    // MARK: - Check-in entry

    /// Where a station's details came from, for the editor's status line.
    enum LookupSource: Equatable {
        case localDirectory
        case qrz
        case notFound(String)
    }

    struct ResolvedStation: Equatable {
        var entry: UserEntry
        var source: LookupSource
    }

    /// Force a QRZ lookup even when the station is already known locally, to fill
    /// in details a local-only record is missing. The refreshed address data is
    /// cached, but the operator's **nickname and persistent notes are preserved**.
    func refreshFromQRZ(callSign: String) async -> ResolvedStation {
        let call = callSign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else {
            return ResolvedStation(entry: UserEntry(callSign: "", name: ""),
                                   source: .notFound("Enter a call sign."))
        }
        guard let client else {
            needsCredentials = true
            return ResolvedStation(entry: UserEntry(callSign: call, name: ""),
                                   source: .notFound("Sign in to QRZ.com to refresh."))
        }

        isBusy = true
        defer { isBusy = false }
        do {
            guard let record = try await client.lookup(callSign: call) else {
                return ResolvedStation(entry: UserEntry(callSign: call, name: ""),
                                       source: .notFound("No QRZ record found for \(call)."))
            }
            // saveDirectoryInfo updates address fields only — nickname and
            // persistent notes already in the directory are left untouched.
            storeDirectoryInfo(record)
            let merged = userDatabase.find(callSign: call) ?? UserEntry(record: record)
            append(log: "Refreshed \(call) from QRZ.")
            return ResolvedStation(entry: merged, source: .qrz)
        } catch {
            return ResolvedStation(entry: UserEntry(callSign: call, name: ""),
                                   source: .notFound("Lookup failed: \(error.localizedDescription)"))
        }
    }

    /// Resolve a call sign for the editor: **the local operator directory first**,
    /// falling back to QRZ only when the station isn't already known. A fresh QRZ
    /// result is cached locally (without disturbing any saved nickname/notes).
    func resolveStation(callSign: String) async -> ResolvedStation {
        let call = callSign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return ResolvedStation(entry: UserEntry(callSign: "", name: ""),
                                                          source: .notFound("Enter a call sign.")) }

        // 1. Local directory — no network needed.
        if let local = userDatabase.find(callSign: call) {
            return ResolvedStation(entry: local, source: .localDirectory)
        }

        // 2. QRZ.
        guard let client else {
            return ResolvedStation(entry: UserEntry(callSign: call, name: ""),
                                   source: .notFound("Not in the local directory, and you are not signed in to QRZ."))
        }

        isBusy = true
        defer { isBusy = false }
        do {
            guard let record = try await client.lookup(callSign: call) else {
                return ResolvedStation(entry: UserEntry(callSign: call, name: ""),
                                       source: .notFound("No QRZ record found for \(call)."))
            }
            storeDirectoryInfo(record)
            return ResolvedStation(entry: UserEntry(record: record), source: .qrz)
        } catch {
            return ResolvedStation(entry: UserEntry(callSign: call, name: ""),
                                   source: .notFound("Lookup failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Check-in editor

    func presentAddCheckIn() { editorTarget = .add }

    func presentEditCheckIn(id: UUID) {
        guard let checkIn = checkIns.first(where: { $0.id == id }) else { return }
        editorTarget = .edit(checkIn)
    }

    func dismissEditor() { editorTarget = nil }

    /// Add a new check-in or update an existing one, and persist the operator's
    /// details (nickname + notes included) to the local directory.
    ///
    /// Set `isReceivingStation` to also make this operator the NTS receiving
    /// station. `keepEditorOpen` leaves the entry window up for the next call
    /// sign ("Save and Add New"). Returns false when the entry was rejected.
    @discardableResult
    func saveCheckIn(
        id: UUID?,
        callSign: String,
        name: String,
        nickname: String,
        city: String,
        county: String,
        state: String,
        persistentNotes: String,
        temporaryNotes: String,
        hasAnnouncement: Bool = false,
        isReceivingStation: Bool = false,
        keepEditorOpen: Bool = false
    ) -> Bool {
        let call = callSign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else {
            errorMessage = "A call sign is required."
            return false
        }

        // Keep any first/last name split we already know, so nickname handling
        // and the directory entry stay accurate after an edit.
        let known = userDatabase.find(callSign: call)
        let entry = UserEntry(
            callSign: call,
            name: name.trimmingCharacters(in: .whitespaces),
            firstName: known?.firstName ?? "",
            lastName: known?.lastName ?? "",
            nickname: nickname.trimmingCharacters(in: .whitespaces),
            street: known?.street ?? "",
            city: city.trimmingCharacters(in: .whitespaces),
            county: county.trimmingCharacters(in: .whitespaces),
            state: state.trimmingCharacters(in: .whitespaces),
            persistentNotes: persistentNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // Only persistent notes are stored; temporary notes stay in this net.
        do {
            try storeOperator(entry, isNew: known == nil)
        } catch {
            errorMessage = "Could not save to the operator directory: \(error.localizedDescription)"
        }

        // Editing a row must not silently un-tick an announcement already read.
        let alreadyRead = id.flatMap { existing in
            checkIns.first(where: { $0.id == existing })?.announcementCompleted
        } ?? false

        let checkIn = CheckIn(
            id: id ?? UUID(), callSign: entry.callSign, name: entry.name,
            nickname: entry.nickname, city: entry.city, county: entry.county,
            state: entry.state, persistentNotes: entry.persistentNotes,
            temporaryNotes: temporaryNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            hasAnnouncement: hasAnnouncement,
            announcementCompleted: hasAnnouncement && alreadyRead)

        if let id, let index = checkIns.firstIndex(where: { $0.id == id }) {
            let previous = checkIns[index].callSign
            checkIns[index] = checkIn
            append(log: previous == entry.callSign
                   ? "Edited \(checkIn.logLine)"
                   : "Edited \(previous) → \(checkIn.logLine)")
        } else {
            checkIns.append(checkIn)
            append(log: checkIn.logLine)
        }

        if isReceivingStation {
            receivingStation = entry.callSign
            receivingNickname = entry.nickname
            append(log: "NTS receiving station set to \(entry.callSign).")
        }

        if !keepEditorOpen { editorTarget = nil }
        return true
    }

    /// Log a break and close the entry window.
    func logBreakFromEditor() {
        logBreak()
        editorTarget = nil
    }

    func deleteCheckIns(ids: Set<UUID>) {
        let removed = checkIns.filter { ids.contains($0.id) }.map(\.callSign)
        checkIns.removeAll { ids.contains($0.id) }
        if !removed.isEmpty {
            append(log: "Deleted \(removed.joined(separator: ", ")).")
        }
    }

    /// Log a net break, as the original CLI's `break` command did.
    func logBreak() {
        append(log: "--- BREAK ---")
    }

    /// Stations flagged as having an announcement or QST to read.
    var announcements: [CheckIn] {
        checkIns.filter(\.hasAnnouncement)
    }

    /// Announcements still waiting to be read on the air.
    /// Counted directly off `checkIns` — building the filtered array first just
    /// to count it allocated on every redraw of the badge.
    var pendingAnnouncementCount: Int {
        checkIns.count { $0.hasAnnouncement && !$0.announcementCompleted }
    }

    /// Tick an announcement off (or back on) as it is read during the net.
    func setAnnouncementCompleted(id: UUID, _ completed: Bool) {
        guard let index = checkIns.firstIndex(where: { $0.id == id }),
              checkIns[index].announcementCompleted != completed else { return }
        checkIns[index].announcementCompleted = completed
        let call = checkIns[index].callSign
        append(log: completed
               ? "✓ Announcement read for \(call)."
               : "Announcement for \(call) marked not yet read.")
    }

    // MARK: - Database management (Edit ▸ Databases…)

    /// Which database a management action targets.
    enum DatabaseKind: String, CaseIterable, Identifiable {
        case reports = "Report Log"
        case operators = "Operator Directory"
        var id: String { rawValue }

        var fileName: String {
            switch self {
            case .reports:   return "netreport.sqlite"
            case .operators: return "users.sqlite"
            }
        }
    }

    func reportRows() -> [ReportRecord] {
        (try? database.allReports()) ?? []
    }

    func operatorRows() -> [UserEntry] {
        (try? userDatabase.allEntries()) ?? []
    }

    func deleteReport(id: Int64) {
        do {
            try database.deleteReport(id: id)
            append(log: "Deleted a report row from the report log.")
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func deleteOperator(callSign: String) {
        do {
            try userDatabase.delete(callSign: callSign)
            append(log: "Removed \(callSign) from the operator directory.")
            refreshOperatorCount()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Save an edited directory entry (used by the database manager).
    func saveOperator(_ entry: UserEntry) {
        do {
            try storeOperator(entry)
            append(log: "Updated \(entry.callSign) in the operator directory.")
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Back up either database to a file the user picks.
    func backupDatabase(_ kind: DatabaseKind) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsOtherFileTypes = true
        let tag = kind == .reports ? "reports" : "users"
        panel.nameFieldStringValue = "netreport-\(tag)-\(NetReportBuilder.timestampToken()).sqlite"
        panel.message = "Save a backup copy of the \(kind.rawValue.lowercased())."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch kind {
            case .reports:   try database.backup(to: url)
            case .operators: try userDatabase.backup(to: url)
            }
            append(log: "\(kind.rawValue) backed up to \(url.path).")
        } catch {
            errorMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    /// Warn, offer a backup, then erase the chosen database.
    func confirmAndErase(_ kind: DatabaseKind) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Erase the \(kind.rawValue.lowercased())?"
        alert.informativeText = kind == .reports
            ? "This permanently deletes all logged net reports and resets the starting "
              + "number. Your operator directory is stored separately and will not be "
              + "affected. This cannot be undone."
            : "This permanently deletes every saved operator, including nicknames and "
              + "persistent notes. Your report log is stored separately and will not be "
              + "affected. This cannot be undone."
        alert.addButton(withTitle: "Back Up, then Erase")
        alert.addButton(withTitle: "Erase Without Backup")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            backupDatabase(kind)
            erase(kind)
        case .alertSecondButtonReturn:
            erase(kind)
        default:
            break
        }
    }

    private func erase(_ kind: DatabaseKind) {
        do {
            switch kind {
            case .reports:
                try database.eraseAll()
                lastResult = nil
                refreshSetupState()
            case .operators:
                try userDatabase.eraseAll()
                refreshOperatorCount()
            }
            append(log: "\(kind.rawValue) erased.")
        } catch {
            errorMessage = "Erase failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Report

    func generateReport() async {
        let receiver = receivingStation.trimmingCharacters(in: .whitespaces).uppercased()
        guard !receiver.isEmpty else {
            errorMessage = "Enter the station receiving the NTS form."
            return
        }
        receivingStation = receiver
        guard trafficMessages >= 0 else {
            errorMessage = "Traffic messages must be 0 or more."
            return
        }

        isBusy = true
        defer { isBusy = false }

        // The receiving station is normally one of tonight's check-ins, already
        // in the directory — so try local first rather than always paying for a
        // QRZ round trip (which can stall 20s on a bad connection). Only use the
        // local copy when it has a surname, since that's what the nickname
        // substitution on the radiogram needs.
        var receivingRecord: HamRecord?
        if let local = userDatabase.find(callSign: receiver), !local.lastName.isEmpty {
            receivingRecord = local.record
        } else if let client {
            receivingRecord = (try? await client.lookup(callSign: receiver)) ?? nil
            if let receivingRecord {
                storeDirectoryInfo(receivingRecord)
            }
        }
        // A missing record is non-fatal: the form still prints, using the call
        // sign (and nickname, if given) alone.

        do {
            let result = try NetReportBuilder.generate(
                userCallSign: operatorCallSign,
                userRecord: operatorRecord,
                receivingStation: receiver,
                receivingRecord: receivingRecord,
                receivingNickname: receivingNickname,
                checkIns: checkIns,
                trafficMessages: trafficMessages,
                outputDirectory: outputDirectory,
                database: database
            )
            lastResult = result
            append(log: "Check-in list saved to \(result.checkinListURL.path)")
            append(log: "Net report saved to \(result.netReportURL.path)")
            append(log: "Message #\(result.messageNumber) logged · \(result.totalCheckins) check-ins.")
            refreshSetupState()
        } catch {
            errorMessage = "Failed to generate report: \(error.localizedDescription)"
        }
    }

    func openCheckinList() {
        guard let url = lastResult?.checkinListURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openNetReport() {
        guard let url = lastResult?.netReportURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealOutputFolder() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([outputDirectory])
    }

    func resetNet() {
        operatorCallSign = ""
        operatorRecord = nil
        netStarted = false
        checkIns = []
        editorTarget = nil
        receivingStation = ""
        receivingNickname = ""
        trafficMessages = 1
        lastResult = nil
        log = []
    }

    // MARK: - Interactive panels (used by both the UI and the File menu)

    func chooseDataFolderInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        panel.message = "Choose a folder for the Net Report database and PDFs (local, synced, or a network share)."
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            chooseDataFolder(url: url)
        }
    }

    private func append(log line: String) {
        log.append(line)
    }
}
