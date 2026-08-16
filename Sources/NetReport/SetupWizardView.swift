import SwiftUI
import NetReportKit

/// First-run setup: QRZ sign-in, where the data lives, and how the two
/// databases get their starting contents. Runs once per machine, so moving to a
/// new computer walks the operator through pointing at a shared data folder and
/// picking up the databases already there.
struct SetupWizardView: View {
    @Environment(NetSession.self) private var session

    @State private var step: Step = .qrz

    enum Step: Int, CaseIterable {
        case qrz, storage, importData, finish

        var title: String {
            switch self {
            case .qrz:        return "QRZ.com Account"
            case .storage:    return "Data Location"
            case .importData: return "Starting Data"
            case .finish:     return "All Set"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Group {
                switch step {
                case .qrz:        QRZStep(onNext: advance)
                case .storage:    StorageStep(onNext: advance)
                case .importData: ImportStep(onNext: advance)
                case .finish:     FinishStep()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            footer
        }
        .frame(width: 560)
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Set Up Net Report").font(.title2.bold())
                    Text(step.title).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            // Step dots.
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            if step != .qrz {
                Button("Back") { retreat() }
            }
            Spacer()
            if step == .finish {
                Button("Start Using Net Report") { session.completeFirstRunSetup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Skip Setup") { session.completeFirstRunSetup() }
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: Navigation

    private func advance() {
        switch step {
        case .qrz:
            step = .storage
        case .storage:
            // Databases already present in a shared folder? Nothing to import.
            step = session.foundExistingData ? .finish : .importData
        case .importData:
            step = .finish
        case .finish:
            session.completeFirstRunSetup()
        }
    }

    private func retreat() {
        switch step {
        case .qrz:        break
        case .storage:    step = .qrz
        case .importData: step = .storage
        case .finish:     step = session.foundExistingData ? .storage : .importData
        }
    }
}

// MARK: - Step 1: QRZ

private struct QRZStep: View {
    @Environment(NetSession.self) private var session
    let onNext: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var saveToKeychain = true
    @State private var signInFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Net Report looks up call signs using your own QRZ.com account. "
                 + "A QRZ XML subscription is needed for full address data.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if session.isSignedIn, let user = session.qrzUsername {
                Label("Signed in as \(user)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Use a different account") { session.signOutAndForgetCredentials() }
            } else {
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
                            .onSubmit { signIn() }
                    }
                }

                Toggle("Save to my Keychain", isOn: $saveToKeychain)
                Text("Saved logins are kept in the macOS Keychain only — never in a "
                     + "file or in the databases.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Sign In") { signIn() }
                        .disabled(session.isBusy
                                  || username.trimmingCharacters(in: .whitespaces).isEmpty
                                  || password.isEmpty)
                    if session.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Skip — don't use QRZ") { onNext() }
                }

                Text("Without QRZ you can still run a net and enter station details by "
                     + "hand, and sign in later from File ▸ QRZ Account…")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signIn() {
        Task {
            if await session.signIn(username: username,
                                    password: password,
                                    saveToKeychain: saveToKeychain) {
                onNext()
            }
        }
    }
}

// MARK: - Step 2: Storage location

private struct StorageStep: View {
    @Environment(NetSession.self) private var session
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose where the databases and report PDFs live. Pick a synced or "
                 + "network folder (iCloud Drive, OneDrive, a shared volume) to use "
                 + "the same data from more than one computer.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Data folder").font(.caption).foregroundStyle(.secondary)
                    Text(session.outputDirectory.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose Folder…") { session.chooseDataFolderInteractive() }
                }
                .padding(4)
            }

            // What's already there — the "new computer" case.
            if session.foundExistingData {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Found existing data in this folder").bold()
                        Text("\(session.reportCount) net report"
                             + "\(session.reportCount == 1 ? "" : "s") · "
                             + "\(session.operatorCount) operator"
                             + "\(session.operatorCount == 1 ? "" : "s") — these will be used as-is.")
                            .font(.callout)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No existing databases here").bold()
                        Text("You'll set up their starting contents next.")
                            .font(.callout)
                    }
                } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                }
            }

            if let error = session.databaseError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Step 3: Starting data

private struct ImportStep: View {
    @Environment(NetSession.self) private var session
    let onNext: () -> Void

    @State private var startingNumberText = "1"
    @State private var operatorsDone = false
    @State private var reportsDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Give each database a starting point. They are independent — set up "
                 + "one, both, or neither.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // --- Operator directory ---
            GroupBox("Operator Directory") {
                VStack(alignment: .leading, spacing: 8) {
                    if session.operatorCount > 0 {
                        Label("\(session.operatorCount) operator"
                              + "\(session.operatorCount == 1 ? "" : "s") ready",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Import operators you already have, or start with an empty "
                             + "directory that fills itself in as you look call signs up.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Import CSV…") {
                                if session.importUserCSVInteractive() != nil { operatorsDone = true }
                            }
                            Button("Start Empty") { operatorsDone = true }
                            if operatorsDone {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        Text("CSV needs a header row with a call sign column; name, "
                             + "nickname, city, county, state, and notes are optional.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(4)
            }

            // --- Report log ---
            GroupBox("Net Report Log") {
                VStack(alignment: .leading, spacing: 8) {
                    if session.reportCount > 0 {
                        Label("\(session.reportCount) report"
                              + "\(session.reportCount == 1 ? "" : "s") imported — next number "
                              + "will be \(session.nextMessageNumber)",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Import your previous nets, or choose the message number "
                             + "your first report should use.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Import CSV…") {
                                if session.importReportCSVInteractive() != nil { reportsDone = true }
                            }
                            Spacer()
                        }
                        HStack {
                            Text("Start at number")
                            TextField("1", text: $startingNumberText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                            Button("Use Number") { applyStartingNumber() }
                            Button("Start Fresh (1)") {
                                startingNumberText = "1"
                                applyStartingNumber()
                            }
                            if reportsDone {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private func applyStartingNumber() {
        guard let number = Int(startingNumberText.trimmingCharacters(in: .whitespaces)),
              number >= 0 else {
            session.errorMessage = "Enter a whole number of 0 or more."
            return
        }
        session.applyStartingNumber(number)
        reportsDone = true
    }
}

// MARK: - Step 4: Finish

private struct FinishStep: View {
    @Environment(NetSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("You're ready to run a net", systemImage: "checkmark.seal.fill")
                .font(.title3.bold())
                .foregroundStyle(.green)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("QRZ").foregroundStyle(.secondary)
                    Text(session.qrzUsername.map { "Signed in as \($0)" }
                         ?? "Not signed in — enter details by hand, or sign in later")
                }
                GridRow {
                    Text("Data folder").foregroundStyle(.secondary)
                    Text(session.outputDirectory.path)
                        .font(.callout.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("Operators").foregroundStyle(.secondary)
                    Text("\(session.operatorCount) saved")
                }
                GridRow {
                    Text("Reports").foregroundStyle(.secondary)
                    Text("\(session.reportCount) logged · next message number "
                         + "\(session.nextMessageNumber)")
                }
            }

            Text("Enter your call sign in the main window and click Start Net to begin. "
                 + "You can change any of this later from the File and Edit menus.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
