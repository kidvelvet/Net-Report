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
import Security
import NetReportKit

/// Stores the operator's QRZ.com login in the macOS Keychain.
///
/// The password never touches `UserDefaults` or any file the app writes — only
/// the Keychain, under a single generic-password item. Saving is optional: an
/// operator can sign in for the session and decline to store anything.
enum KeychainStore {
    /// Service identifier for the app's QRZ credential item.
    private static let service = "com.w7skw.netreport.qrz"

    enum KeychainError: Error, LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let code):
                let message = SecCopyErrorMessageString(code, nil) as String?
                return message ?? "Keychain error \(code)."
            }
        }
    }

    /// The saved credentials, or nil when nothing is stored (or access was denied).
    static func load() -> QRZCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let found = item as? [String: Any],
              let account = found[kSecAttrAccount as String] as? String,
              let data = found[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return QRZCredentials(username: account, password: password)
    }

    /// Save (replacing any existing entry) the QRZ login.
    static func save(_ credentials: QRZCredentials) throws {
        remove()   // simplest correct upsert: clear then insert
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentials.username,
            kSecValueData as String: Data(credentials.password.utf8),
            kSecAttrLabel as String: "Net Report — QRZ.com",
            // ThisDeviceOnly: the credential stays on this Mac and is excluded
            // from encrypted backups and Migration Assistant transfers.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            // Stated explicitly rather than relying on the default, so the
            // password is never copied into iCloud Keychain.
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Delete the stored login, if any.
    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
