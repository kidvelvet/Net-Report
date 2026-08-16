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

import SwiftUI
import NetReportKit

struct ContentView: View {
    @Environment(NetSession.self) private var session
    @State private var selection: Set<UUID> = []

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            OperatorBar()
            Divider()

            if let dbError = session.databaseError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(dbError).font(.caption)
                    Spacer()
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
            }

            if session.netStarted {
                HSplitView {
                    VStack(alignment: .leading, spacing: 10) {
                        CheckInEntry()
                        CheckInTable(selection: $selection)
                    }
                    .padding(12)
                    .frame(minWidth: 460)

                    VStack(alignment: .leading, spacing: 12) {
                        ReportPanel()
                        ActivityLog()
                        DatabasePanel()
                    }
                    .padding(12)
                    .frame(minWidth: 300)
                }
            } else {
                ContentUnavailableView(
                    "Start a Net",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Enter your call sign above and start the net to begin logging check-ins.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if session.isBusy {
                ProgressView().controlSize(.small).padding(8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .alert("Notice",
               isPresented: Binding(
                   get: { session.errorMessage != nil },
                   set: { if !$0 { session.errorMessage = nil } }
               )) {
            Button("OK", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .sheet(item: Binding(
            get: { activeSheet },
            set: { newValue in
                // Only one sheet shows at a time; dismissing means "skip this step".
                guard newValue == nil else { return }
                // Dismissing a step means "skip it".
                if session.needsFirstRunSetup { session.completeFirstRunSetup() }
                else if session.needsCredentials { session.dismissCredentialsPrompt() }
                else if session.needsDatabaseSetup { session.skipSetup() }
                else { session.dismissEditor() }
            }
        )) { sheet in
            switch sheet {
            case .firstRunSetup:      SetupWizardView()
            case .credentials:        QRZSignInView()
            case .databaseSetup:      DatabaseSetupView()
            case .checkInEditor(let target): CheckInEditorView(target: target)
            }
        }
    }

    /// First-run setup wins over everything; then the one-off prompts; then the
    /// check-in editor.
    private var activeSheet: ActiveSheet? {
        if session.needsFirstRunSetup { return .firstRunSetup }
        if session.needsCredentials { return .credentials }
        if session.needsDatabaseSetup { return .databaseSetup }
        if let target = session.editorTarget { return .checkInEditor(target) }
        return nil
    }

    private enum ActiveSheet: Identifiable {
        case firstRunSetup
        case credentials
        case databaseSetup
        case checkInEditor(NetSession.EditorTarget)

        var id: String {
            switch self {
            case .firstRunSetup:          return "firstRunSetup"
            case .credentials:            return "credentials"
            case .databaseSetup:          return "databaseSetup"
            case .checkInEditor(let t):   return "editor-\(t.id)"
            }
        }
    }
}

// MARK: - Check-in editor (secondary window)

/// Add or edit one check-in. Looks the call sign up in the local operator
/// directory first and only falls back to QRZ when it isn't already known,
/// filling in name, city, county, and state automatically.
private struct CheckInEditorView: View {
    @Environment(NetSession.self) private var session
    let target: NetSession.EditorTarget

    @State private var callSign = ""
    @State private var name = ""
    @State private var nickname = ""
    @State private var city = ""
    @State private var county = ""
    @State private var state = ""
    @State private var persistentNotes = ""
    @State private var temporaryNotes = ""
    @State private var status: NetSession.LookupSource?
    @State private var lastLookedUp = ""
    @State private var isReceivingStation = false
    @State private var hasAnnouncement = false
    @FocusState private var callSignFocused: Bool

    private var isEditing: Bool { target.existing != nil }
    private var canSave: Bool { !callSign.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit Check-in" : "Add Check-in")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Call sign")
                    HStack(spacing: 6) {
                        TextField("K7ABC", text: $callSign)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .frame(width: 130)
                            .focused($callSignFocused)
                            .onSubmit { lookUp() }
                        Button("Look Up") { lookUp() }
                            .disabled(session.isBusy || !canSave)
                        Button {
                            refreshFromQRZ()
                        } label: {
                            Image(systemName: "arrow.clockwise.icloud")
                        }
                        .help("Force a QRZ.com lookup to fill in missing details. "
                              + "Your nickname and persistent notes are kept.")
                        .disabled(session.isBusy || !canSave)
                        if session.isBusy { ProgressView().controlSize(.small) }
                    }
                }
                GridRow {
                    Text("Name")
                    TextField("Full name", text: $name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Nickname")
                    TextField("optional", text: $nickname).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("City")
                    TextField("City", text: $city).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("County")
                    TextField("County", text: $county).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("State")
                    TextField("State", text: $state)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                GridRow(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Persistent Notes")
                        Text("saved").font(.caption2).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $persistentNotes)
                        .font(.body)
                        .frame(height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.4)))
                }
                GridRow(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Temporary Notes")
                        Text("this net only").font(.caption2).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $temporaryNotes)
                        .font(.body)
                        .frame(height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.4)))
                }
            }

            Text("Persistent notes are remembered for this operator at every net. "
                 + "Temporary notes appear in tonight's log and report only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Announcement", isOn: $hasAnnouncement)
                .help("This station has an announcement or QST to read. "
                      + "Flagged stations are collected in the Announcements window.")

            Toggle("NTS Receiving Station", isOn: $isReceivingStation)
                .help("Use this operator as the station receiving the NTS form; "
                      + "their call sign and nickname fill in the report automatically.")

            if let status {
                Label {
                    Text(statusText(status)).font(.caption)
                } icon: {
                    Image(systemName: statusIcon(status))
                        .foregroundStyle(statusColor(status))
                }
            }

            Divider()

            HStack {
                Button("Cancel") { session.dismissEditor() }
                    .keyboardShortcut(.cancelAction)
                Button("Break") { saveThenBreak() }
                    .help("Save this entry (if any), log a net break, and close this window")
                Spacer()
                if !isEditing {
                    Button("Save and Add New") { save(keepOpen: true) }
                        .disabled(!canSave)
                }
                Button("Save") { save(keepOpen: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            loadExisting()
            callSignFocused = true
        }
    }

    private func loadExisting() {
        guard let existing = target.existing else { return }
        callSign = existing.callSign
        name = existing.name
        nickname = existing.nickname
        city = existing.city
        county = existing.county
        state = existing.state
        persistentNotes = existing.persistentNotes
        temporaryNotes = existing.temporaryNotes
        hasAnnouncement = existing.hasAnnouncement
        lastLookedUp = existing.callSign
        // Reflect whether this operator is already the NTS receiving station.
        isReceivingStation = !existing.callSign.isEmpty
            && existing.callSign.caseInsensitiveCompare(session.receivingStation) == .orderedSame
    }

    /// Clear the form for the next call sign, keeping the window open.
    private func resetForm() {
        callSign = ""
        name = ""
        nickname = ""
        city = ""
        county = ""
        state = ""
        persistentNotes = ""
        temporaryNotes = ""
        status = nil
        lastLookedUp = ""
        isReceivingStation = false
        hasAnnouncement = false
        callSignFocused = true
    }

    /// Force a QRZ lookup to fill in details missing from the local record.
    /// Nickname and persistent notes are deliberately left as they are.
    private func refreshFromQRZ() {
        let call = callSign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return }
        callSign = call
        Task {
            let resolved = await session.refreshFromQRZ(callSign: call)
            status = resolved.source
            lastLookedUp = call
            if case .notFound = resolved.source { return }

            let entry = resolved.entry
            name = entry.name
            city = entry.city
            county = entry.county
            state = entry.state
            // Fill only what's still blank; never clobber the operator's own text.
            if nickname.isEmpty { nickname = entry.nickname }
            if persistentNotes.isEmpty { persistentNotes = entry.persistentNotes }
        }
    }

    /// Resolve the call sign and fill in the details.
    private func lookUp() {
        let call = callSign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return }
        callSign = call
        Task {
            let resolved = await session.resolveStation(callSign: call)
            status = resolved.source
            lastLookedUp = call
            if case .notFound = resolved.source { return }

            let entry = resolved.entry
            name = entry.name
            city = entry.city
            county = entry.county
            state = entry.state
            // Don't clobber a nickname/notes the user is already typing.
            // Temporary notes are never pre-filled — they're per-net.
            if nickname.isEmpty { nickname = entry.nickname }
            if persistentNotes.isEmpty { persistentNotes = entry.persistentNotes }
        }
    }

    /// Save the entry. With `keepOpen`, clear the form for the next call sign
    /// instead of closing the window.
    @discardableResult
    private func save(keepOpen: Bool) -> Bool {
        let saved = session.saveCheckIn(
            id: target.existing?.id,
            callSign: callSign, name: name, nickname: nickname,
            city: city, county: county, state: state,
            persistentNotes: persistentNotes, temporaryNotes: temporaryNotes,
            hasAnnouncement: hasAnnouncement,
            isReceivingStation: isReceivingStation,
            keepEditorOpen: keepOpen)
        if saved && keepOpen { resetForm() }
        return saved
    }

    /// Save whatever has been entered (so nothing is lost), then log the break
    /// and close the window.
    private func saveThenBreak() {
        if canSave {
            // Keep the window open through the save so a failure doesn't close
            // it and discard the entry.
            guard save(keepOpen: true) else { return }
        }
        session.logBreakFromEditor()
    }

    private func statusText(_ source: NetSession.LookupSource) -> String {
        switch source {
        case .localDirectory: return "Filled in from your local operator directory."
        case .qrz:            return "Looked up on QRZ.com and saved to your local directory."
        case .notFound(let m): return m
        }
    }

    private func statusIcon(_ source: NetSession.LookupSource) -> String {
        switch source {
        case .localDirectory: return "internaldrive.fill"
        case .qrz:            return "antenna.radiowaves.left.and.right"
        case .notFound:       return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ source: NetSession.LookupSource) -> Color {
        switch source {
        case .localDirectory: return .green
        case .qrz:            return .blue
        case .notFound:       return .orange
        }
    }
}

// MARK: - QRZ sign-in

private struct QRZSignInView: View {
    @Environment(NetSession.self) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var saveToKeychain = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to QRZ.com").font(.title2.bold())
                Text("Net Report looks up call signs with your own QRZ account. "
                     + "A QRZ XML subscription is required for full address data.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("User name")
                    TextField("Your QRZ call sign or user name", text: $username)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password")
                    SecureField("QRZ password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submit() }
                }
            }

            Toggle("Save to my Keychain", isOn: $saveToKeychain)
            Text("Saved logins are kept in the macOS Keychain — never in a file or "
                 + "in the report database.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if session.isSignedIn {
                    Button("Cancel") { session.dismissCredentialsPrompt() }
                }
                Spacer()
                Button("Not Now") { session.dismissCredentialsPrompt() }
                Button("Sign In") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(session.isBusy
                              || username.trimmingCharacters(in: .whitespaces).isEmpty
                              || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { username = session.qrzUsername ?? "" }
    }

    private func submit() {
        Task { await session.signIn(username: username,
                                    password: password,
                                    saveToKeychain: saveToKeychain) }
    }
}

// MARK: - First-run database setup

private struct DatabaseSetupView: View {
    @Environment(NetSession.self) private var session
    @State private var startingText = "1"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up the Net Report Database").font(.title2.bold())
                Text("The database is empty. Import your existing message log, or choose the "
                     + "starting message number for your first net report.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Import existing CSV").font(.headline)
                        Text("Load a message_index.csv in the original format.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import CSV…") { session.importReportCSVInteractive() }
                }
                .padding(6)
            }

            GroupBox {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Start fresh").font(.headline)
                        Text("Set the message number your first net report will use.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("1", text: $startingText)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Button("Use Number") {
                        if let number = Int(startingText.trimmingCharacters(in: .whitespaces)), number >= 0 {
                            session.applyStartingNumber(number)
                        } else {
                            session.errorMessage = "Enter a whole number of 0 or more."
                        }
                    }
                }
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Skip (start at 1)") { session.skipSetup() }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Database panel

private struct DatabasePanel: View {
    @Environment(NetSession.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GroupBox("Databases") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Data folder").font(.caption).foregroundStyle(.secondary)
                Text(session.outputDirectory.path)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Change Folder…") { session.chooseDataFolderInteractive() }
                    Spacer()
                    // Edit / back up / erase either database in one place.
                    Button("Manage…") { openWindow(id: WindowID.databases) }
                }
            }
            .padding(4)
        }
    }
}

// MARK: - Per-box font control

/// Compact stepper that adjusts (and persists) the font size of one box.
struct FontSizeControl: View {
    @Environment(FontSettings.self) private var fonts
    let box: FontSettings.Box

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "textformat.size")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Stepper(
                value: Binding(get: { fonts.size(box) }, set: { fonts.setSize(box, $0) }),
                in: FontSettings.range,
                step: 1
            ) {
                Text("\(Int(fonts.size(box)))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16)
            }
            .labelsHidden()
        }
        .controlSize(.mini)
        .help("Font size for the \(box.title)")
    }
}

// MARK: - Operator bar

private struct OperatorBar: View {
    @Environment(NetSession.self) private var session
    @Environment(FontSettings.self) private var fonts

    var body: some View {
        @Bindable var session = session
        let size = fonts.cgSize(.operatorBar)

        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Net Control").font(.system(size: size + 3, weight: .bold))
                Text("Oregon D1 Net").font(.system(size: max(size - 2, 8)))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // QRZ account status / sign-in.
            Button {
                session.presentCredentialsPrompt()
            } label: {
                if let user = session.qrzUsername {
                    Label("QRZ: \(user)", systemImage: "person.badge.key.fill")
                } else {
                    Label("Sign in to QRZ", systemImage: "exclamationmark.lock.fill")
                }
            }
            .font(.system(size: max(size - 1, 8)))
            .help(session.isSignedIn
                  ? "Signed in to QRZ.com — click to change accounts"
                  : "Sign in to QRZ.com to look up call signs")

            Divider().frame(height: 18)

            if session.netStarted {
                Label(session.operatorCallSign, systemImage: "person.fill")
                    .font(.system(size: size, design: .monospaced))
                Text("·").foregroundStyle(.secondary)
                Text("\(session.totalCheckins) check-ins")
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                Button("New Net") { session.resetNet() }
            } else {
                TextField("Your call sign", text: $session.operatorCallSign)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: size, design: .monospaced))
                    .frame(width: 160)
                    .onSubmit { Task { await session.startNet() } }
                Button("Start Net") { Task { await session.startNet() } }
                    .keyboardShortcut(.return)
                    .disabled(session.isBusy)
            }

            Divider().frame(height: 18)
            FontSizeControl(box: .operatorBar)
        }
        .padding(12)
    }
}

// MARK: - Check-in entry

private struct CheckInEntry: View {
    @Environment(NetSession.self) private var session
    @Environment(FontSettings.self) private var fonts

    var body: some View {
        @Bindable var session = session
        let size = fonts.cgSize(.checkInEntry)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Add Check-in").font(.system(size: size + 1, weight: .semibold))
                Spacer()
                FontSizeControl(box: .checkInEntry)
            }
            HStack {
                Button {
                    session.presentAddCheckIn()
                } label: {
                    Label("Add Check-in…", systemImage: "plus.circle.fill")
                        .font(.system(size: size))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("k", modifiers: .command)

                Button("Log Break") { session.logBreak() }
                    .font(.system(size: size))
                Spacer()
                AnnouncementsButton(size: size)
            }
            Text("Opens a window to enter the call sign, nickname, and notes. "
                 + "City, county, and state fill in automatically.")
                .font(.system(size: max(size - 2, 8)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Opens the Announcements window, badged with the current count.
private struct AnnouncementsButton: View {
    @Environment(NetSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    let size: CGFloat

    var body: some View {
        // Badge counts announcements still to read, so it clears as they're done.
        let pending = session.pendingAnnouncementCount
        Button {
            openWindow(id: WindowID.announcements)
        } label: {
            Label(pending > 0 ? "Announcements (\(pending))" : "Announcements",
                  systemImage: "megaphone.fill")
                .font(.system(size: size))
        }
        .tint(pending > 0 ? .orange : nil)
        .help("Show every station flagged with an announcement or QST")
    }
}

// MARK: - Check-in table

private struct CheckInTable: View {
    @Environment(NetSession.self) private var session
    @Environment(FontSettings.self) private var fonts
    @Binding var selection: Set<UUID>
    @State private var pendingDeletion: Set<UUID>?

    /// "Delete K7ABC?" for one row, or a count for several.
    private var deletionPrompt: String {
        guard let ids = pendingDeletion else { return "" }
        if ids.count == 1, let id = ids.first,
           let checkIn = session.checkIns.first(where: { $0.id == id }) {
            return "Delete \(checkIn.callSign)?"
        }
        return "Delete \(ids.count) check-ins?"
    }

    var body: some View {
        let size = fonts.cgSize(.checkInTable)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Check-ins").font(.system(size: size + 1, weight: .semibold))
                Spacer()
                FontSizeControl(box: .checkInTable)
                Button(role: .destructive) {
                    pendingDeletion = selection
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }

            Table(session.checkIns, selection: $selection) {
                TableColumn("") { checkIn in
                    if checkIn.hasAnnouncement {
                        Image(systemName: checkIn.announcementCompleted
                              ? "checkmark.circle.fill" : "megaphone.fill")
                            .foregroundStyle(checkIn.announcementCompleted ? .green : .orange)
                            .help(checkIn.announcementCompleted
                                  ? "Announcement read" : "Has an announcement")
                    }
                }
                .width(18)
                TableColumn("Call Sign") {
                    Text($0.callSign).font(.system(size: size, design: .monospaced))
                }
                .width(min: 80, ideal: 90)
                TableColumn("Name", value: \.name)
                TableColumn("Nickname", value: \.nickname)
                TableColumn("City", value: \.city)
                TableColumn("County", value: \.county)
                TableColumn("State", value: \.state).width(min: 44, ideal: 50)
                TableColumn("Notes", value: \.persistentNotes)
                TableColumn("Tonight", value: \.temporaryNotes)
            }
            .font(.system(size: size))
            .frame(minHeight: 280)
            // Right-click a row to edit or delete it.
            .contextMenu(forSelectionType: CheckIn.ID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("Edit…") { session.presentEditCheckIn(id: id) }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDeletion = ids }
                } else if ids.count > 1 {
                    Button("Delete \(ids.count) Check-ins…", role: .destructive) {
                        pendingDeletion = ids
                    }
                } else {
                    Button("Add Check-in…") { session.presentAddCheckIn() }
                }
            } primaryAction: { ids in
                // Double-click opens the editor.
                if let id = ids.first, ids.count == 1 { session.presentEditCheckIn(id: id) }
            }
            .confirmationDialog(
                deletionPrompt,
                isPresented: Binding(get: { pendingDeletion != nil },
                                     set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let ids = pendingDeletion {
                        session.deleteCheckIns(ids: ids)
                        selection.subtract(ids)
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            }
        }
    }
}

// MARK: - Report panel

private struct ReportPanel: View {
    @Environment(NetSession.self) private var session
    @Environment(FontSettings.self) private var fonts

    var body: some View {
        @Bindable var session = session
        let size = fonts.cgSize(.reportPanel)

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Receiving station")
                    Spacer()
                    TextField("CALL", text: $session.receivingStation)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: size, design: .monospaced))
                        .frame(width: 120)
                }
                HStack {
                    Text("Nickname")
                    Spacer()
                    TextField("optional", text: $session.receivingNickname)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                Text("Replaces their first name on the radiogram — e.g. “Theodore Marks” "
                     + "becomes “Ted Marks”.")
                    .font(.system(size: max(size - 2, 8)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Traffic messages")
                    Spacer()
                    Stepper(value: $session.trafficMessages, in: 0...99) {
                        Text("\(session.trafficMessages)").monospacedDigit()
                    }
                    .frame(width: 120)
                }

                Button {
                    Task { await session.generateReport() }
                } label: {
                    Label("Generate Report", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isBusy
                          || session.receivingStation.trimmingCharacters(in: .whitespaces).isEmpty)

                if let result = session.lastResult {
                    Divider()
                    Text(result.nts.summaryText)
                        .font(.system(size: max(size - 1, 8), design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("Open Check-in List") { session.openCheckinList() }
                        Button("Open Net Report") { session.openNetReport() }
                        Button("Reveal Folder") { session.revealOutputFolder() }
                    }
                }
            }
            .font(.system(size: size))
            .padding(4)
        } label: {
            HStack {
                Text("NTS Report").font(.system(size: size + 1, weight: .semibold))
                Spacer()
                FontSizeControl(box: .reportPanel)
            }
        }
    }
}

// MARK: - Activity log

private struct ActivityLog: View {
    @Environment(NetSession.self) private var session
    @Environment(FontSettings.self) private var fonts

    var body: some View {
        let size = fonts.cgSize(.activityLog)

        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        // Indices rather than Array(enumerated()): the log grows
                        // all night and that rebuilt a paired array every redraw.
                        ForEach(session.log.indices, id: \.self) { index in
                            // Entries can span lines (a check-in carries its
                            // notes underneath), so let them wrap fully — this
                            // is what net control reads from during the net.
                            Text(session.log[index])
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .font(.system(size: size, design: .monospaced))
                    .padding(4)
                }
                .onChange(of: session.log.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            .frame(minHeight: 120)
        } label: {
            HStack {
                Text("Activity").font(.system(size: size + 2, weight: .semibold))
                Spacer()
                FontSizeControl(box: .activityLog)
            }
        }
    }
}
