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
    private static let checkinListFolderKey = "checkinListFolder"
    private static let netReportsFolderKey = "netReportsFolder"
    private var client: QRZClient?

    // MARK: Report destinations

    /// Where each kind of PDF is filed. Nil means "the usual subfolder of the
    /// data folder", so the default keeps following the data folder around;
    /// setting one pins that kind of report to a folder of its own.
    private(set) var checkinListDirectoryOverride: URL?
    private(set) var netReportsDirectoryOverride: URL?

    /// The folder check-in lists are actually written to.
    var checkinListDirectory: URL {
        checkinListDirectoryOverride
            ?? outputDirectory.appendingPathComponent(NetReportBuilder.checkinListFolder,
                                                      isDirectory: true)
    }

    /// The folder net reports are actually written to.
    var netReportsDirectory: URL {
        netReportsDirectoryOverride
            ?? outputDirectory.appendingPathComponent(NetReportBuilder.netReportsFolder,
                                                      isDirectory: true)
    }

    /// Pick a folder for one kind of report. Passing nil restores the default.
    func setCheckinListDirectory(_ url: URL?) {
        checkinListDirectoryOverride = url
        UserDefaults.standard.set(url, forKey: Self.checkinListFolderKey)
        append(log: url == nil
               ? "Check-in lists will use the default folder again."
               : "Check-in lists will be saved to \(checkinListDirectory.path).")
    }

    func setNetReportsDirectory(_ url: URL?) {
        netReportsDirectoryOverride = url
        UserDefaults.standard.set(url, forKey: Self.netReportsFolderKey)
        append(log: url == nil
               ? "Net reports will use the default folder again."
               : "Net reports will be saved to \(netReportsDirectory.path).")
    }

    func chooseCheckinListDirectoryInteractive() {
        if let url = chooseFolder(titled: "Choose where check-in list PDFs are saved.",
                                  startingAt: checkinListDirectory) {
            setCheckinListDirectory(url)
        }
    }

    func chooseNetReportsDirectoryInteractive() {
        if let url = chooseFolder(titled: "Choose where net report PDFs are saved.",
                                  startingAt: netReportsDirectory) {
            setNetReportsDirectory(url)
        }
    }

    /// Put both kinds of report back under the data folder.
    func resetReportDirectories() {
        setCheckinListDirectory(nil)
        setNetReportsDirectory(nil)
    }

    private func chooseFolder(titled message: String, startingAt: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = startingAt
        panel.message = message
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func revealCheckinListFolder() { reveal(checkinListDirectory) }
    func revealNetReportsFolder() { reveal(netReportsDirectory) }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

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
        checkinListDirectoryOverride = UserDefaults.standard.url(forKey: Self.checkinListFolderKey)
        netReportsDirectoryOverride = UserDefaults.standard.url(forKey: Self.netReportsFolderKey)

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

    /// Bumped on every write to either database, so the database manager
    /// window — open beside a running net — reloads instead of going stale.
    private(set) var databaseRevision = 0

    /// Re-read the cached operator count. Use after directory-only changes so we
    /// don't scan the report log for nothing.
    private func refreshOperatorCount() {
        operatorCount = userDatabase.count()
        databaseRevision &+= 1
    }

    /// Every write to the operator directory goes through these two helpers, so
    /// the cached `operatorCount` can never be left stale by a new call site.
    private func storeDirectoryInfo(_ record: HamRecord) {
        try? userDatabase.saveDirectoryInfo(record)
        refreshOperatorCount()   // also bumps databaseRevision
    }

    /// `isNew: false` skips the recount: `save` upserts on the call sign, so if
    /// the caller already established the row exists, the write is an UPDATE and
    /// the count cannot have changed. That spares a COUNT(*) per check-in.
    private func storeOperator(_ entry: UserEntry, isNew: Bool = true) throws {
        try userDatabase.save(entry)
        if isNew { refreshOperatorCount() } else { databaseRevision &+= 1 }
    }

    /// Re-read the cached report figures after report-log changes.
    private func refreshReportCounts() {
        reportCount = database.reportCount()
        nextMessageNumber = database.nextMessageNumber()
        databaseRevision &+= 1
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

        // Local directory first, then QRZ — the editor's own precedence, so a
        // known operator starts the net with no network at all.
        let resolved = await resolveStation(callSign: call)
        let entry = resolved.entry
        if case .notFound = resolved.source {
            errorMessage = client == nil
                ? "Not signed in to QRZ — starting the net with placeholder details. "
                    + "Edit your check-in to fill them in."
                : "Couldn't look up \(call) on QRZ — starting the net anyway; "
                    + "edit your entry to fill in the details."
        }
        let record = entry.hasStationDetails ? entry.record : nil
        operatorRecord = record
        // The directory's nickname and persistent notes come along either way:
        // they are what net control reads out about each station.
        let seed: CheckIn = record.map {
            CheckIn(record: $0, nickname: entry.nickname, persistentNotes: entry.persistentNotes)
        } ?? CheckIn(callSign: call, name: "Unknown", nickname: entry.nickname,
                     city: "Unknown", county: "Unknown", persistentNotes: entry.persistentNotes)
        checkIns = [seed]
        netStarted = true
        append(log: "Net started. Operator \(call) checked in.")
    }

    /// The operator's record for the NTS form. Read from the directory at
    /// report time, so correcting your own entry mid-net (or on a later net)
    /// reaches the form instead of the details captured at Start Net.
    private var currentOperatorRecord: HamRecord? {
        userDatabase.find(callSign: operatorCallSign)
            .flatMap { $0.hasStationDetails ? $0.record : nil } ?? operatorRecord
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
        guard !call.isEmpty else { return Self.enterCallSign }
        // No sign-in sheet from here: this runs from inside the entry window,
        // and a second sheet would replace it and lose what was typed.
        let resolved = await lookUpOnQRZ(call, local: userDatabase.find(callSign: call),
                                         notSignedIn: "Sign in to QRZ.com (File menu) to refresh.")
        if resolved.source == .qrz { append(log: "Refreshed \(call) from QRZ.") }
        return resolved
    }

    /// Resolve a call sign for the editor: **the local operator directory first**,
    /// falling back to QRZ only when the station isn't already known. A fresh QRZ
    /// result is cached locally (without disturbing any saved nickname/notes).
    ///
    /// A directory row with no name or location — one holding only a nickname,
    /// say — doesn't count as known: QRZ is still asked, so a row like that
    /// can't permanently hide an operator's details.
    func resolveStation(callSign: String) async -> ResolvedStation {
        let call = callSign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return Self.enterCallSign }

        // 1. Local directory — no network needed.
        let local = userDatabase.find(callSign: call)
        if let local, local.hasStationDetails {
            return ResolvedStation(entry: local, source: .localDirectory)
        }

        // 2. QRZ.
        return await lookUpOnQRZ(call, local: local,
                                 notSignedIn: "Not in the local directory, and you are not signed in to QRZ.")
    }

    private static let enterCallSign = ResolvedStation(entry: UserEntry(callSign: "", name: ""),
                                                       source: .notFound("Enter a call sign."))

    /// Ask QRZ about `call` and cache the answer. Whatever the outcome, the
    /// returned entry carries any nickname and notes already in the directory
    /// (`local`, which the caller has already read).
    private func lookUpOnQRZ(_ call: String, local: UserEntry?, notSignedIn: String) async -> ResolvedStation {
        func miss(_ message: String) -> ResolvedStation {
            ResolvedStation(entry: local ?? UserEntry(callSign: call, name: ""), source: .notFound(message))
        }
        guard let client else { return miss(notSignedIn) }

        isBusy = true
        defer { isBusy = false }
        do {
            guard let record = try await client.lookup(callSign: call) else {
                return miss("No QRZ record found for \(call).")
            }
            // saveDirectoryInfo updates address fields only — nickname and
            // persistent notes already in the directory are left untouched.
            storeDirectoryInfo(record)
            return ResolvedStation(entry: userDatabase.find(callSign: call) ?? UserEntry(record: record),
                                   source: .qrz)
        } catch {
            return miss("Lookup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Check-in editor

    func presentAddCheckIn() { editorTarget = .add }

    func presentEditCheckIn(id: UUID) {
        guard let checkIn = checkIns.first(where: { $0.id == id }) else { return }
        editorTarget = .edit(checkIn)
    }

    func dismissEditor() { editorTarget = nil }

    /// One extra operator checking in from the same station as the primary
    /// entry — a second person at one radio, which happens regularly on a net.
    struct AdditionalStation: Identifiable, Equatable {
        let id = UUID()
        var callSign: String = ""
        var nickname: String = ""
        /// The last lookup done for this line. Only trusted while it still
        /// matches the call sign in the field — retyping invalidates it.
        var lookup: Lookup?

        struct Lookup: Equatable {
            var callSign: String
            /// Nil when nothing was found (or the lookup could not run).
            var entry: UserEntry?
            var source: LookupSource
        }

        var normalizedCall: String {
            callSign.trimmingCharacters(in: .whitespaces).uppercased()
        }

        var isBlank: Bool { normalizedCall.isEmpty }

        /// The lookup result, if it is for the call sign currently typed.
        var currentLookup: Lookup? {
            lookup?.callSign == normalizedCall ? lookup : nil
        }
    }

    /// Look up one extra line the same way the main call sign is looked up.
    func lookUp(_ station: AdditionalStation) async -> AdditionalStation.Lookup? {
        let call = station.normalizedCall
        guard !call.isEmpty else { return nil }
        let resolved = await resolveStation(callSign: call)
        if case .notFound = resolved.source {
            return .init(callSign: call, entry: nil, source: resolved.source)
        }
        return .init(callSign: call, entry: resolved.entry, source: resolved.source)
    }

    /// Save the primary entry and any additional stations checking in with it.
    ///
    /// The extras are resolved the same way the editor resolves a call sign —
    /// local directory first, QRZ only on a miss — and anything still unknown
    /// inherits the primary's location, since by definition they are at the
    /// same radio. Returns true when the primary entry was accepted.
    @discardableResult
    func saveCheckIns(
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
        additional: [AdditionalStation] = [],
        primaryLookedUp: Bool = true,
        keepEditorOpen: Bool = false
    ) async -> Bool {
        // Saved without Look Up: resolve it now, exactly as the extra lines
        // are, and keep whatever is known for every field left blank — rather
        // than writing those blanks over the directory entry.
        var known: UserEntry?
        if !primaryLookedUp {
            known = await resolveStation(callSign: callSign).entry
        }

        // Keep the editor open through the primary save so a rejection doesn't
        // close the window and lose what was typed.
        guard saveCheckIn(
            id: id, callSign: callSign, name: name, nickname: nickname,
            city: city, county: county, state: state,
            persistentNotes: persistentNotes, temporaryNotes: temporaryNotes,
            hasAnnouncement: hasAnnouncement, isReceivingStation: isReceivingStation,
            fillingBlanksFrom: known,
            keepEditorOpen: true
        ) else { return false }

        let fallback = (city: city.trimmingCharacters(in: .whitespaces),
                        county: county.trimmingCharacters(in: .whitespaces),
                        state: state.trimmingCharacters(in: .whitespaces))
        var seen: Set<String> = [callSign.trimmingCharacters(in: .whitespaces).uppercased()]

        for station in additional where !station.isBlank {
            let call = station.normalizedCall
            guard seen.insert(call).inserted else {
                append(log: "Skipped duplicate \(call) in this entry.")
                continue
            }
            await addAdditionalStation(call,
                                       nickname: station.nickname.trimmingCharacters(in: .whitespaces),
                                       lookup: station.currentLookup,
                                       sharingLocation: fallback)
        }

        if !keepEditorOpen { editorTarget = nil }
        return true
    }

    /// Resolve and append one extra station, reusing whatever the directory
    /// already knows so a saved nickname or persistent notes are not lost.
    private func addAdditionalStation(
        _ call: String,
        nickname: String,
        lookup: AdditionalStation.Lookup?,
        sharingLocation fallback: (city: String, county: String, state: String)
    ) async {
        // A line already looked up in the editor is trusted as-is — the
        // operator has seen the result — so one call sign costs one lookup,
        // not one in the editor and another on save. Anything else resolves
        // exactly as the editor would: directory first, QRZ on a miss.
        var entry: UserEntry
        if let lookup {
            entry = lookup.entry ?? userDatabase.find(callSign: call) ?? UserEntry(callSign: call, name: "")
        } else {
            entry = await resolveStation(callSign: call).entry
        }

        // Persist a nickname typed here; the rest of the row is what the
        // directory already holds, so its notes are kept.
        if !nickname.isEmpty, nickname != entry.nickname {
            entry.nickname = nickname
            try? storeOperator(entry)
        }

        // Fields with nothing in them fall back to the host station's location.
        let checkIn = CheckIn.sharingStation(
            callSign: call,
            record: entry.record,
            nickname: entry.nickname,
            persistentNotes: entry.persistentNotes,
            fallbackCity: fallback.city,
            fallbackCounty: fallback.county,
            fallbackState: fallback.state)
        checkIns.append(checkIn)
        append(log: checkIn.logLine)
    }

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
        fillingBlanksFrom fill: UserEntry? = nil,
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
        ).fillingBlanks(from: fill?.callSign == call ? fill : nil)
        // Only persistent notes are stored; temporary notes stay in this net.
        // A call sign nobody knows anything about isn't written at all: an
        // empty row would later pass for a directory hit and block QRZ.
        let worthStoring = known != nil || entry.hasStationDetails
            || !entry.nickname.isEmpty || !entry.persistentNotes.isEmpty
        if worthStoring {
            do {
                try storeOperator(entry, isNew: known == nil)
            } catch {
                errorMessage = "Could not save to the operator directory: \(error.localizedDescription)"
            }
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
        } else if id != nil,
                  receivingStation.caseInsensitiveCompare(entry.callSign) == .orderedSame {
            // The editor shows the box ticked for the receiving station's own
            // row, so unticking it there must actually un-set it.
            receivingStation = ""
            receivingNickname = ""
            append(log: "\(entry.callSign) is no longer the NTS receiving station.")
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
            refreshReportCounts()   // the count and next message number changed
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
    /// Returns true only when a backup was actually written.
    @discardableResult
    func backupDatabase(_ kind: DatabaseKind) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsOtherFileTypes = true
        let tag = kind == .reports ? "reports" : "users"
        panel.nameFieldStringValue = "netreport-\(tag)-\(NetReportBuilder.timestampToken()).sqlite"
        panel.message = "Save a backup copy of the \(kind.rawValue.lowercased())."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            switch kind {
            case .reports:   try database.backup(to: url)
            case .operators: try userDatabase.backup(to: url)
            }
            append(log: "\(kind.rawValue) backed up to \(url.path).")
            return true
        } catch {
            errorMessage = "Backup failed: \(error.localizedDescription)"
            return false
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
            // "Back up, then erase" means exactly that: a cancelled save panel
            // or a failed copy leaves the database alone.
            guard backupDatabase(kind) else {
                append(log: "Erase cancelled — no backup was made.")
                return
            }
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
        guard !isGeneratingReport else { return }
        if let last = lastResult, currentFingerprint == reportedFingerprint {
            errorMessage = "Nothing has changed since message #\(last.messageNumber) was saved, "
                + "so no new report was made."
            return
        }
        isGeneratingReport = true
        defer { isGeneratingReport = false }

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
        // A full local record (with a last name for the form's address line)
        // needs no network. Otherwise ask QRZ, and if it has nothing either,
        // use whatever the directory does hold rather than printing nothing.
        let local = userDatabase.find(callSign: receiver)
        var receivingRecord = local.flatMap { $0.lastName.isEmpty ? nil : $0.record }
        if receivingRecord == nil, let client,
           let fetched = (try? await client.lookup(callSign: receiver)) ?? nil {
            storeDirectoryInfo(fetched)
            receivingRecord = fetched
        }
        receivingRecord = receivingRecord ?? local.flatMap { $0.hasStationDetails ? $0.record : nil }
        // A missing record is non-fatal: the form still prints, using the call
        // sign (and nickname, if given) alone.

        do {
            let result = try NetReportBuilder.generate(
                userCallSign: operatorCallSign,
                userRecord: currentOperatorRecord,
                receivingStation: receiver,
                receivingRecord: receivingRecord,
                receivingNickname: receivingNickname,
                checkIns: checkIns,
                trafficMessages: trafficMessages,
                outputDirectory: outputDirectory,
                checkinListDirectory: checkinListDirectoryOverride,
                netReportsDirectory: netReportsDirectoryOverride,
                database: database
            )
            lastResult = result
            reportedFingerprint = currentFingerprint
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

    /// Everything that ends up in a report. Two reports with equal fingerprints
    /// are the same report.
    struct ReportFingerprint: Equatable {
        var rows: [[String]]
        var receivingStation: String
        var receivingNickname: String
        var trafficMessages: Int
    }

    /// What a report generated right now would contain.
    var currentFingerprint: ReportFingerprint {
        ReportFingerprint(
            rows: checkIns.map(\.tableRow),
            receivingStation: receivingStation.trimmingCharacters(in: .whitespaces).uppercased(),
            receivingNickname: receivingNickname.trimmingCharacters(in: .whitespaces),
            trafficMessages: max(0, trafficMessages))
    }

    /// What the last report this net generated contained.
    private var reportedFingerprint: ReportFingerprint?

    /// Guards against a second report starting while one is in flight — two
    /// clicks on Generate would otherwise log two messages.
    private var isGeneratingReport = false

    /// True when quitting now would lose work: check-ins are logged and the
    /// last report (if any) no longer matches them.
    ///
    /// Compared by content rather than "has a report been made": check-ins
    /// added after Generate Report used to be silently discarded on quit,
    /// because one report had already been made.
    var hasUnsavedNet: Bool {
        netStarted && !checkIns.isEmpty && currentFingerprint != reportedFingerprint
    }

    /// Write both PDFs for an in-progress net before it is thrown away — on
    /// quit, or when New Net replaces it.
    ///
    /// Synchronous on purpose: this runs inside `applicationShouldTerminate`,
    /// where there is nowhere to await. That means no QRZ round trip — the
    /// receiving station is resolved from the local directory only — and a
    /// missing receiving station is tolerated rather than refused, because
    /// rescuing the check-in list matters more than a complete NTS form.
    @discardableResult
    func saveUnsavedReports() -> Bool {
        // Re-checked here, not just when the dialog opened: a Generate Report
        // already in flight can finish while the quit dialog is up.
        guard hasUnsavedNet else { return true }
        let receiver = receivingStation.trimmingCharacters(in: .whitespaces).uppercased()
        let receivingRecord = userDatabase.find(callSign: receiver)?.record

        do {
            let result = try NetReportBuilder.generate(
                userCallSign: operatorCallSign,
                userRecord: currentOperatorRecord,
                receivingStation: receiver,
                receivingRecord: receivingRecord,
                receivingNickname: receivingNickname,
                checkIns: checkIns,
                trafficMessages: max(0, trafficMessages),
                outputDirectory: outputDirectory,
                checkinListDirectory: checkinListDirectoryOverride,
                netReportsDirectory: netReportsDirectoryOverride,
                database: database
            )
            lastResult = result
            reportedFingerprint = currentFingerprint
            refreshSetupState()
            append(log: "Saved — check-in list: \(result.checkinListURL.path)")
            append(log: "Saved — net report: \(result.netReportURL.path)")
            return true
        } catch {
            errorMessage = "Could not save the reports: \(error.localizedDescription)"
            return false
        }
    }

    func revealOutputFolder() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([outputDirectory])
    }

    /// How the unsaved work is described in the quit and New Net prompts.
    var unsavedNetSummary: String {
        let n = totalCheckins
        let count = "\(n) check-in\(n == 1 ? "" : "s")"
        return lastResult == nil
            ? "A net is in progress with \(count) and no report generated yet."
            : "The net has changed since message #\(lastResult!.messageNumber) was saved "
              + "(\(count) now)."
    }

    /// File ▸ New Net. Clearing a net is as final as quitting, so it asks the
    /// same question first instead of silently discarding the check-ins.
    func startNewNet() {
        if hasUnsavedNet {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Start a new net?"
            alert.informativeText = unsavedNetSummary + " Saving writes both the check-in "
                + "list and the net report first; otherwise the check-in list is discarded."
            alert.addButton(withTitle: "Save Reports & Start New")
            alert.addButton(withTitle: "Discard & Start New")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard saveUnsavedReports() else { return }
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        resetNet()
    }

    private func resetNet() {
        operatorCallSign = ""
        operatorRecord = nil
        netStarted = false
        checkIns = []
        editorTarget = nil
        receivingStation = ""
        receivingNickname = ""
        trafficMessages = 1
        lastResult = nil
        reportedFingerprint = nil
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

