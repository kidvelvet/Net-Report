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

/// Minimal QRZ XML reader.
///
/// QRZ responses look like:
/// ```xml
/// <QRZDatabase xmlns="http://xmldata.qrz.com">
///   <Session><Key>…</Key><Error>…</Error></Session>
///   <Callsign><call>…</call><fname>…</fname><name>…</name>…</Callsign>
/// </QRZDatabase>
/// ```
/// We only need the text of a handful of leaf elements, so rather than build a
/// full tree (as the Python did with ElementTree) we capture the first
/// occurrence of each element of interest. This matches the Python's
/// "find first by local name" semantics, since QRZ returns one `<Session>` and
/// at most one `<Callsign>`.
public final class QRZResponseParser: NSObject, XMLParserDelegate {
    /// Leaf elements whose text we keep.
    private static let targets: Set<String> = [
        "Key", "Error", "Message",          // <Session>
        "call", "fname", "name",            // <Callsign>
        "addr1", "addr2", "county", "state",
    ]

    private var values: [String: String] = [:]
    private var currentTarget: String?
    private var buffer = ""

    public override init() { super.init() }

    public func parse(_ data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Explicitly refuse external entities. This is already Foundation's
        // default, but we state it because this parses a *remote* response: if
        // the endpoint were spoofed or compromised, an XXE payload could
        // otherwise be used to read local files or probe internal hosts. Being
        // explicit also stops a future refactor from silently enabling it.
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.parse()
        return values
    }

    private static func localName(_ qualified: String) -> String {
        guard let colon = qualified.lastIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: colon)...])
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let local = Self.localName(elementName)
        if local == "Callsign" {
            values["__hasCallsign"] = "1"
        }
        if Self.targets.contains(local) {
            currentTarget = local
            buffer = ""
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentTarget != nil { buffer += string }
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = Self.localName(elementName)
        guard currentTarget == local else { return }
        // First occurrence wins, mirroring the Python's _find_first/_child_text.
        if values[local] == nil {
            values[local] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentTarget = nil
        buffer = ""
    }
}
