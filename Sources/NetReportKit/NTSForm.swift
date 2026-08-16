import Foundation

/// The fully-resolved field values printed on the ARRL radiogram / NTS form.
/// Computed once and consumed by both the on-screen summary and the PDF drawer,
/// mirroring the `nts_data` dictionary the Python assembled.
public struct NTSForm: Sendable, Equatable {
    public var messageNumber: String
    public var precedence: String
    public var handling: String          // HX code
    public var check: String
    public var fromCall: String
    public var placeOrigin: String
    public var timeFiled: String
    public var dateFiled: String
    public var toStation: String
    public var toName: String
    public var toStreet: String
    public var toCityState: String
    public var line1: String
    public var line2: String

    public init(
        messageNumber: String,
        precedence: String = "Routine",
        handling: String = "HXG",
        check: String = "10",
        fromCall: String,
        placeOrigin: String,
        timeFiled: String,
        dateFiled: String,
        toStation: String,
        toName: String,
        toStreet: String,
        toCityState: String,
        line1: String,
        line2: String
    ) {
        self.messageNumber = messageNumber
        self.precedence = precedence
        self.handling = handling
        self.check = check
        self.fromCall = fromCall
        self.placeOrigin = placeOrigin
        self.timeFiled = timeFiled
        self.dateFiled = dateFiled
        self.toStation = toStation
        self.toName = toName
        self.toStreet = toStreet
        self.toCityState = toCityState
        self.line1 = line1
        self.line2 = line2
    }

    /// A compact textual rendering for the on-screen NTS summary, matching the
    /// lines the Python CLI printed before saving.
    public var summaryText: String {
        """
        Message Number: \(messageNumber) | \(precedence) | \(handling) | \(fromCall) | \(check) | \(placeOrigin) | \(dateFiled)
        TO: \(toStation)
        Line 1: \(line1)
        Line 2: \(line2)
        From: \(fromCall)
        """
    }
}

/// Outcome of generating a net report. The check-in list and the radiogram are
/// written as two separate, never-overwritten PDFs.
public struct NetReportResult: Sendable {
    public let nts: NTSForm
    public let checkinListURL: URL
    public let netReportURL: URL
    public let messageNumber: Int
    public let totalCheckins: Int
    public let message: String
}

/// Orchestrates a complete net report: assembles the NTS form, renders the PDF,
/// and appends the message-index row. This is the Swift equivalent of the tail
/// end of `ham_lookup.py`'s `main()`.
public enum NetReportBuilder {

    /// Build the NTS form values from the net inputs.
    ///
    /// `receivingNickname` replaces the receiving operator's given name on the
    /// form — e.g. W1AW "Theodore Marks" with nickname "Ted" prints as
    /// "Ted Marks".
    public static func makeNTSForm(
        messageNumber: Int,
        userCallSign: String,
        userRecord: HamRecord?,
        receivingStation: String,
        receivingRecord: HamRecord?,
        receivingNickname: String = "",
        totalCheckins: Int,
        trafficMessages: Int,
        date: Date = Date()
    ) -> NTSForm {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.component(.day, from: date)

        let monthName = monthFormatter.string(from: date)
        let timeFiled = timeFormatter.string(from: date)

        let userCity = userRecord?.city ?? "Unknown"
        let userState = userRecord?.state ?? "Unknown"

        let line1 = "Oregon D1 Net Report \(monthName)"
        let line2 = "\(day) checkins \(totalCheckins) traffic \(trafficMessages)"

        let toName: String
        let toStreet: String
        let toCityState: String
        let nickname = receivingNickname.trimmingCharacters(in: .whitespaces)
        if let r = receivingRecord {
            toName = "\(r.callSign) - \(r.displayName(nickname: nickname))"
            toStreet = r.street
            toCityState = "\(r.city), \(r.state)"
        } else {
            // No QRZ record: still honour a nickname the operator typed.
            toName = nickname.isEmpty ? receivingStation : "\(receivingStation) - \(nickname)"
            toStreet = "Unknown"
            toCityState = "Unknown"
        }

        return NTSForm(
            messageNumber: String(messageNumber),
            fromCall: userCallSign,
            placeOrigin: "\(userCity), \(userState)",
            timeFiled: timeFiled,
            dateFiled: "\(monthName) \(day)",
            toStation: receivingStation,
            toName: toName,
            toStreet: toStreet,
            toCityState: toCityState,
            line1: line1,
            line2: line2
        )
    }

    /// Subfolder names (under the output directory) for each PDF kind.
    public static let checkinListFolder = "Checkin List"
    public static let netReportsFolder = "Net Reports"

    // Formatters are built once and reused: DateFormatter is expensive to
    // create, and these run on every report and filename.
    private static let monthFormatter = posixFormatter("MMMM")
    private static let timeFormatter = posixFormatter("HHmm")
    private static let fileTokenFormatter = posixFormatter("yyyyMMdd_HHmmss")

    private static func posixFormatter(_ format: String) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = format
        return fmt
    }

    /// Date+time token used in filenames so reports are never overwritten,
    /// e.g. `20260221_200027`.
    public static func timestampToken(for date: Date = Date()) -> String {
        fileTokenFormatter.string(from: date)
    }

    public static func checkinListFilename(for date: Date = Date()) -> String {
        "checkin_list_\(timestampToken(for: date)).pdf"
    }

    public static func netReportFilename(for date: Date = Date()) -> String {
        "net_report_\(timestampToken(for: date)).pdf"
    }

    /// Generate the report into `outputDirectory`, writing two never-overwritten
    /// PDFs — the check-in list (in `Checkin List/`) and the radiogram net report
    /// (in `Net Reports/`) — and logging a row in the database. Returns the
    /// resolved NTS form and both paths.
    public static func generate(
        userCallSign: String,
        userRecord: HamRecord?,
        receivingStation: String,
        receivingRecord: HamRecord?,
        receivingNickname: String = "",
        checkIns: [CheckIn],
        trafficMessages: Int,
        outputDirectory: URL,
        database: NetDatabase,
        date: Date = Date()
    ) throws -> NetReportResult {
        let fm = FileManager.default
        let checkinDir = outputDirectory.appendingPathComponent(checkinListFolder, isDirectory: true)
        let netReportDir = outputDirectory.appendingPathComponent(netReportsFolder, isDirectory: true)
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: checkinDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: netReportDir, withIntermediateDirectories: true)

        let messageNumber = database.nextMessageNumber()
        let total = checkIns.count

        let nts = makeNTSForm(
            messageNumber: messageNumber,
            userCallSign: userCallSign,
            userRecord: userRecord,
            receivingStation: receivingStation,
            receivingRecord: receivingRecord,
            receivingNickname: receivingNickname,
            totalCheckins: total,
            trafficMessages: trafficMessages,
            date: date
        )

        let checkinURL = checkinDir.appendingPathComponent(checkinListFilename(for: date))
        let netReportURL = netReportDir.appendingPathComponent(netReportFilename(for: date))

        let header = ["Call Sign", "Name", "Nickname", "City", "County", "Notes"]
        let rows = [header] + checkIns.map(\.tableRow)
        try RadiogramPDF.writeCheckinList(to: checkinURL, tableRows: rows, generatedAt: date)
        try RadiogramPDF.writeNetReport(to: netReportURL, nts: nts, generatedAt: date)

        // Log the net report (radiogram) as the recorded artifact, matching the
        // single pdf_file column the original CSV used.
        try database.appendReport(
            messageNumber: messageNumber,
            userCallSign: userCallSign,
            receivingStation: receivingStation,
            checkins: total,
            trafficMessages: trafficMessages,
            pdfPath: netReportURL.path,
            timestamp: date
        )

        return NetReportResult(
            nts: nts,
            checkinListURL: checkinURL,
            netReportURL: netReportURL,
            messageNumber: messageNumber,
            totalCheckins: total,
            message: "Saved check-in list and net report."
        )
    }
}
