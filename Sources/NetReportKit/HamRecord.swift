import Foundation

/// A station record as returned by the QRZ XML callsign database.
///
/// Mirrors the fields the original `ham_lookup.py` pulled from QRZ. Missing
/// fields fall back to `"Unknown"`, matching the Python behaviour so downstream
/// report rows are never blank.
public struct HamRecord: Sendable, Equatable, Identifiable {
    public var callSign: String
    /// Full name as QRZ reports it, e.g. "Theodore Marks".
    public var name: String
    /// Given name alone ("Theodore"), kept so a nickname can replace just it.
    public var firstName: String
    /// Surname alone ("Marks").
    public var lastName: String
    public var street: String
    public var city: String
    public var county: String
    public var state: String

    public var id: String { callSign }

    public init(
        callSign: String,
        name: String,
        firstName: String = "",
        lastName: String = "",
        street: String,
        city: String,
        county: String,
        state: String
    ) {
        self.callSign = callSign
        self.name = name
        self.firstName = firstName
        self.lastName = lastName
        self.street = street
        self.city = city
        self.county = county
        self.state = state
    }

    /// The name to print, with `nickname` substituted for the given name:
    /// "Theodore Marks" + nickname "Ted" → "Ted Marks".
    ///
    /// Falls back to the full name when no nickname is supplied, and to the
    /// nickname alone when no surname is known.
    public func displayName(nickname: String) -> String {
        let nick = nickname.trimmingCharacters(in: .whitespaces)
        guard !nick.isEmpty else { return name }
        let last = lastName.trimmingCharacters(in: .whitespaces)
        return last.isEmpty ? nick : "\(nick) \(last)"
    }
}

/// A single net check-in row, as shown in the report table.
///
/// `nickname` is the optional free-text token the operator can append after a
/// call sign (e.g. `K7ABC Steve`); it is preserved verbatim, not upper-cased.
public struct CheckIn: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var callSign: String
    public var name: String
    public var nickname: String
    public var city: String
    public var county: String
    public var state: String
    /// Notes kept in the operator directory and reused at every net.
    public var persistentNotes: String
    /// Notes that apply to tonight's net only — never written to the database.
    public var temporaryNotes: String
    /// This station has an announcement or QST to read during the net. Like
    /// temporary notes, this applies to one net and is not stored.
    public var hasAnnouncement: Bool
    /// The announcement has been read on the air. Ticked off during the net.
    public var announcementCompleted: Bool

    public init(
        id: UUID = UUID(),
        callSign: String,
        name: String,
        nickname: String = "",
        city: String,
        county: String,
        state: String = "",
        persistentNotes: String = "",
        temporaryNotes: String = "",
        hasAnnouncement: Bool = false,
        announcementCompleted: Bool = false
    ) {
        self.id = id
        self.callSign = callSign
        self.name = name
        self.nickname = nickname
        self.city = city
        self.county = county
        self.state = state
        self.persistentNotes = persistentNotes
        self.temporaryNotes = temporaryNotes
        self.hasAnnouncement = hasAnnouncement
        self.announcementCompleted = announcementCompleted
    }

    /// Build a check-in from a station record, carrying local nickname/notes.
    public init(
        record: HamRecord,
        nickname: String = "",
        persistentNotes: String = "",
        temporaryNotes: String = "",
        hasAnnouncement: Bool = false
    ) {
        self.init(
            callSign: record.callSign,
            name: record.name,
            nickname: nickname,
            city: record.city,
            county: record.county,
            state: record.state,
            persistentNotes: persistentNotes,
            temporaryNotes: temporaryNotes,
            hasAnnouncement: hasAnnouncement
        )
    }

    /// Both kinds of note as one string, for the report's single Notes column.
    public var combinedNotes: String {
        [persistentNotes, temporaryNotes]
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    /// The row as ordered cells: Call Sign, Name, Nickname, City, County, Notes.
    public var tableRow: [String] {
        [callSign, name, nickname, city, county, combinedNotes]
    }

    /// Multi-line summary for the activity log, which net control reads from
    /// during the net — so it carries both kinds of note, labelled.
    public var logLine: String {
        var line = "\(callSign) — \(name)"
        if !nickname.isEmpty { line += " (\(nickname))" }
        let place = [city, county].filter { !$0.isEmpty }.joined(separator: ", ")
        if !place.isEmpty { line += " · \(place)" }
        if hasAnnouncement {
            line += announcementCompleted ? "  ✓ ANNOUNCEMENT (read)" : "  ★ ANNOUNCEMENT"
        }
        if !persistentNotes.isEmpty { line += "\n    Notes: \(persistentNotes)" }
        if !temporaryNotes.isEmpty { line += "\n    Tonight: \(temporaryNotes)" }
        return line
    }
}
