import SwiftUI

@main
struct NetReportApp: App {
    @State private var session = NetSession()
    @State private var fonts = FontSettings()

    var body: some Scene {
        WindowGroup("Net Report") {
            ContentView()
                .environment(session)
                .environment(fonts)
                .frame(minWidth: 820, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Net") { session.resetNet() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Reveal Reports Folder") { session.revealOutputFolder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Add Check-in…") { session.presentAddCheckIn() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!session.netStarted)

                WindowMenuItems()

                Divider()

                Button("QRZ Account…") { session.presentCredentialsPrompt() }
                Button("Sign Out of QRZ") { session.signOutAndForgetCredentials() }
                    .disabled(!session.isSignedIn && !session.credentialsAreSaved)

                Divider()

                Button("Choose Data Folder…") { session.chooseDataFolderInteractive() }
                Button("Import Net Reports from CSV…") { session.importReportCSVInteractive() }
                Button("Import Operators from CSV…") { session.importUserCSVInteractive() }

                Divider()

                Button("Run Setup Again…") { session.restartFirstRunSetup() }
            }

            // Database management lives under Edit.
            CommandGroup(after: .pasteboard) {
                Divider()
                DatabaseMenuItems(session: session)
            }

            CommandGroup(after: .toolbar) {
                Button("Reset Font Sizes") { fonts.resetAll() }
            }
        }

        Window("Announcements", id: WindowID.announcements) {
            AnnouncementsView()
                .environment(session)
                .environment(fonts)
        }

        Window("Databases", id: WindowID.databases) {
            DatabaseManagerView()
                .environment(session)
                .environment(fonts)
        }
    }
}

enum WindowID {
    static let announcements = "announcements"
    static let databases = "databases"
}

/// File-menu entries that open the app's secondary windows.
private struct WindowMenuItems: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Announcements") { openWindow(id: WindowID.announcements) }
            .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

/// Edit-menu entries for editing, backing up, or erasing either database.
private struct DatabaseMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    let session: NetSession

    var body: some View {
        Button("Edit Databases…") { openWindow(id: WindowID.databases) }
            .keyboardShortcut("d", modifiers: [.command, .shift])

        Menu("Report Database") {
            Button("Edit…") { openWindow(id: WindowID.databases) }
            Button("Back Up…") { session.backupDatabase(.reports) }
            Button("Erase…", role: .destructive) { session.confirmAndErase(.reports) }
        }

        Menu("Operator Directory") {
            Button("Edit…") { openWindow(id: WindowID.databases) }
            Button("Back Up…") { session.backupDatabase(.operators) }
            Button("Erase…", role: .destructive) { session.confirmAndErase(.operators) }
        }
    }
}
