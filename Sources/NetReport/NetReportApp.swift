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

/// Confirms before the app quits. Check-ins live in memory until a report is
/// generated, so quitting mid-net would silently discard them — the prompt says
/// so explicitly in that case.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app at launch so the prompt can describe what's at stake.
    static weak var session: NetSession?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "Quit Net Report?"

        if let session = Self.session, session.netStarted, session.totalCheckins > 0 {
            let n = session.totalCheckins
            let reported = session.lastResult != nil
            alert.alertStyle = reported ? .informational : .warning
            alert.informativeText = reported
                ? "A net is still open with \(n) check-in\(n == 1 ? "" : "s"). Your report has "
                  + "already been saved; the check-in list itself is not kept after quitting."
                : "A net is in progress with \(n) check-in\(n == 1 ? "" : "s") and no report "
                  + "generated yet. Quitting now discards the check-in list — this cannot be undone."
        } else {
            alert.alertStyle = .informational
            alert.informativeText = "Your databases and saved reports are already on disk."
        }

        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct NetReportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = NetSession()
    @State private var fonts = FontSettings()

    var body: some Scene {
        WindowGroup("Net Report") {
            ContentView()
                .environment(session)
                .environment(fonts)
                .frame(minWidth: 820, minHeight: 600)
                .onAppear { AppDelegate.session = session }
                // Red close button quits (with confirmation) rather than
                // leaving the app running windowless in the Dock.
                .background(WindowCloseInterceptor())
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
