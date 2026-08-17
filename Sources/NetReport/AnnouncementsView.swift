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

/// Standalone window listing every station flagged with an announcement or QST,
/// so net control can read them off in one place.
struct AnnouncementsView: View {
    @Environment(NetSession.self) private var session
    @Environment(FontSettings.self) private var fonts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let size = fonts.cgSize(.activityLog)
        let items = session.announcements

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Announcements & QSTs", systemImage: "megaphone.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                if !items.isEmpty {
                    // Counted from `items` we already have, rather than
                    // re-scanning every check-in.
                    let done = items.count { $0.announcementCompleted }
                    Text("\(done) of \(items.count) read")
                        .foregroundStyle(done == items.count ? .green : .secondary)
                }
                FontSizeControl(box: .activityLog)
            }
            .padding(12)
            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    "No Announcements",
                    systemImage: "megaphone",
                    description: Text("Tick “Announcement” when adding or editing a "
                                      + "check-in and that station will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            AnnouncementRow(
                                checkIn: item,
                                size: size,
                                isCompleted: Binding(
                                    get: { item.announcementCompleted },
                                    set: { session.setAnnouncementCompleted(id: item.id, $0) }
                                )
                            )
                            if item.id != items.last?.id { Divider() }
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 300)
    }
}

private struct AnnouncementRow: View {
    let checkIn: CheckIn
    let size: CGFloat
    @Binding var isCompleted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Tick off each announcement as it is read on the air.
            Toggle(isOn: $isCompleted) {
                Text("Read")
                    .font(.system(size: max(size - 2, 8)))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .help(isCompleted ? "Marked as read — click to undo"
                              : "Mark this announcement as read")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(checkIn.callSign)
                        .font(.system(size: size + 2, weight: .bold, design: .monospaced))
                    Text(displayName)
                        .font(.system(size: size + 1))
                    Spacer()
                    let place = [checkIn.city, checkIn.state].filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    if !place.isEmpty {
                        Text(place).font(.system(size: size)).foregroundStyle(.secondary)
                    }
                }
                if !checkIn.persistentNotes.isEmpty {
                    Text("Notes: \(checkIn.persistentNotes)")
                        .font(.system(size: size))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !checkIn.temporaryNotes.isEmpty {
                    Text("Tonight: \(checkIn.temporaryNotes)")
                        .font(.system(size: size))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if checkIn.persistentNotes.isEmpty && checkIn.temporaryNotes.isEmpty {
                    Text("(no notes recorded)")
                        .font(.system(size: size)).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            // Completed items stay in place but recede, so the remaining ones
            // are what stands out while reading.
            .strikethrough(isCompleted, color: .secondary)
            .opacity(isCompleted ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayName: String {
        checkIn.nickname.isEmpty ? checkIn.name : "\(checkIn.name) (\(checkIn.nickname))"
    }
}
