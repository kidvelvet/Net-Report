import SwiftUI
import NetReportKit

/// Standalone window for managing both databases: browse and edit the operator
/// directory, review the report log, and back up or erase either one.
struct DatabaseManagerView: View {
    @Environment(NetSession.self) private var session

    @State private var kind: NetSession.DatabaseKind = .operators
    @State private var operators: [UserEntry] = []
    @State private var reports: [ReportRecord] = []
    @State private var operatorSelection: Set<String> = []
    @State private var reportSelection: Set<Int64> = []
    @State private var editingOperator: UserEntry?
    @State private var pendingOperatorDelete: String?
    @State private var pendingReportDelete: ReportRecord?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Database", selection: $kind) {
                ForEach(NetSession.DatabaseKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            Group {
                switch kind {
                case .operators: operatorTable
                case .reports:   reportTable
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 380)
        .onAppear(perform: reload)
        .onChange(of: kind) { _, _ in reload() }
        .sheet(item: $editingOperator) { entry in
            OperatorEditorView(entry: entry) { updated in
                session.saveOperator(updated)
                editingOperator = nil
                // Patch the row in place rather than re-reading the table.
                if let i = operators.firstIndex(where: { $0.id == updated.id }) {
                    operators[i] = updated
                }
            } onCancel: {
                editingOperator = nil
            }
        }
        .confirmationDialog(
            pendingOperatorDelete.map { "Delete \($0) from the operator directory?" } ?? "",
            isPresented: Binding(get: { pendingOperatorDelete != nil },
                                 set: { if !$0 { pendingOperatorDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let call = pendingOperatorDelete {
                    session.deleteOperator(callSign: call)
                    operatorSelection.remove(call)
                    operators.removeAll { $0.callSign == call }
                }
                pendingOperatorDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingOperatorDelete = nil }
        } message: {
            Text("This removes their saved nickname and persistent notes. It does not "
                 + "affect tonight's check-in list.")
        }
        .confirmationDialog(
            pendingReportDelete.map { "Delete report #\($0.messageNumber)?" } ?? "",
            isPresented: Binding(get: { pendingReportDelete != nil },
                                 set: { if !$0 { pendingReportDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingReportDelete {
                    session.deleteReport(id: row.id)
                    reportSelection.remove(row.id)
                    reports.removeAll { $0.id == row.id }
                }
                pendingReportDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingReportDelete = nil }
        } message: {
            Text("The generated PDF files are not deleted — only this log entry.")
        }
    }

    // MARK: - Tables

    private var operatorTable: some View {
        Table(operators, selection: $operatorSelection) {
            TableColumn("Call Sign") { Text($0.callSign).font(.body.monospaced()) }
                .width(min: 80, ideal: 90)
            TableColumn("Name", value: \.name)
            TableColumn("Nickname", value: \.nickname)
            TableColumn("City", value: \.city)
            TableColumn("County", value: \.county)
            TableColumn("State", value: \.state).width(min: 44, ideal: 50)
            TableColumn("Persistent Notes", value: \.persistentNotes)
            TableColumn("Updated", value: \.updatedAt).width(min: 110, ideal: 130)
        }
        .contextMenu(forSelectionType: UserEntry.ID.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Edit…") { editingOperator = operators.first { $0.id == id } }
                Divider()
                Button("Delete…", role: .destructive) { pendingOperatorDelete = id }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first {
                editingOperator = operators.first { $0.id == id }
            }
        }
    }

    private var reportTable: some View {
        Table(reports, selection: $reportSelection) {
            TableColumn("#") { Text(String($0.messageNumber)).monospacedDigit() }
                .width(min: 34, ideal: 40)
            TableColumn("Date", value: \.timestamp).width(min: 130, ideal: 150)
            TableColumn("From", value: \.userCallSign).width(min: 70, ideal: 80)
            TableColumn("To", value: \.receivingStation).width(min: 70, ideal: 80)
            TableColumn("Check-ins") { Text(String($0.checkins)).monospacedDigit() }
                .width(min: 60, ideal: 70)
            TableColumn("Traffic") { Text(String($0.trafficMessages)).monospacedDigit() }
                .width(min: 50, ideal: 60)
            TableColumn("PDF", value: \.pdfFile)
        }
        .contextMenu(forSelectionType: ReportRecord.ID.self) { ids in
            if ids.count == 1, let id = ids.first,
               let row = reports.first(where: { $0.id == id }) {
                Button("Reveal PDF in Finder") { revealPDF(row) }
                Divider()
                Button("Delete…", role: .destructive) { pendingReportDelete = row }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(countLabel).foregroundStyle(.secondary).font(.callout)
            Spacer()
            Button("Back Up…") { session.backupDatabase(kind) }
            Button("Erase All…", role: .destructive) {
                session.confirmAndErase(kind)
                reload()
            }
        }
        .padding(12)
    }

    private var countLabel: String {
        switch kind {
        case .operators:
            return "\(operators.count) operator\(operators.count == 1 ? "" : "s") · \(kind.fileName)"
        case .reports:
            return "\(reports.count) report\(reports.count == 1 ? "" : "s") · \(kind.fileName)"
        }
    }

    /// Load only the table on screen — reading both meant querying (and holding)
    /// the whole of the other database for nothing.
    private func reload() {
        switch kind {
        case .operators: operators = session.operatorRows()
        case .reports:   reports = session.reportRows()
        }
    }

    private func revealPDF(_ row: ReportRecord) {
        let url = URL(fileURLWithPath: row.pdfFile)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            session.errorMessage = "That PDF is no longer at \(row.pdfFile)."
        }
    }
}

// MARK: - Operator editor

/// Edit one saved operator's directory entry.
private struct OperatorEditorView: View {
    @State var entry: UserEntry
    let onSave: (UserEntry) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(entry.callSign)").font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    TextField("Full name", text: $entry.name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("First / Last")
                    HStack {
                        TextField("First", text: $entry.firstName).textFieldStyle(.roundedBorder)
                        TextField("Last", text: $entry.lastName).textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("Nickname")
                    TextField("optional", text: $entry.nickname).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Street")
                    TextField("Street", text: $entry.street).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("City")
                    TextField("City", text: $entry.city).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("County")
                    TextField("County", text: $entry.county).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("State")
                    TextField("State", text: $entry.state)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                GridRow(alignment: .top) {
                    Text("Persistent Notes")
                    TextEditor(text: $entry.persistentNotes)
                        .font(.body)
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.4)))
                }
            }

            Text("The call sign identifies this entry and can't be changed here — "
                 + "delete and re-add to correct it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { onSave(entry) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 470)
    }
}
