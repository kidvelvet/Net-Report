import Foundation
import Observation

/// Per-box UI font sizes, adjustable at runtime and persisted across launches.
///
/// Each on-screen box (operator bar, check-in entry, check-in table, NTS report
/// panel, activity log) carries its own size so they can be tuned independently
/// for readability. Values are stored in `UserDefaults` under a single key.
@MainActor
@Observable
final class FontSettings {

    enum Box: String, CaseIterable, Identifiable {
        case operatorBar
        case checkInEntry
        case checkInTable
        case reportPanel
        case activityLog

        var id: String { rawValue }

        var title: String {
            switch self {
            case .operatorBar:  return "Net Control bar"
            case .checkInEntry: return "Add Check-in"
            case .checkInTable: return "Check-ins table"
            case .reportPanel:  return "NTS Report panel"
            case .activityLog:  return "Activity log"
            }
        }

        var defaultSize: Double {
            switch self {
            case .operatorBar:  return 13
            case .checkInEntry: return 13
            case .checkInTable: return 13
            case .reportPanel:  return 12
            case .activityLog:  return 11
            }
        }
    }

    /// Allowed size range for every box.
    static let range: ClosedRange<Double> = 9...28

    private static let defaultsKey = "fontSizes"

    private var sizes: [String: Double]

    init() {
        var loaded: [String: Double] = [:]
        if let raw = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) {
            for (key, value) in raw {
                if let number = value as? NSNumber { loaded[key] = number.doubleValue }
            }
        }
        sizes = loaded
    }

    /// Current size for a box (its default if never changed).
    func size(_ box: Box) -> Double {
        sizes[box.rawValue] ?? box.defaultSize
    }

    /// Same as `size(_:)` but typed for SwiftUI's `Font.system(size:)`.
    func cgSize(_ box: Box) -> CGFloat { CGFloat(size(box)) }

    func setSize(_ box: Box, _ value: Double) {
        let clamped = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        sizes[box.rawValue] = clamped
        persist()
    }

    /// Restore one box to its default.
    func reset(_ box: Box) {
        sizes[box.rawValue] = nil
        persist()
    }

    /// Restore every box to its default.
    func resetAll() {
        sizes = [:]
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(sizes, forKey: Self.defaultsKey)
    }
}
