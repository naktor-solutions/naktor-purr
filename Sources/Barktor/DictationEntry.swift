import Foundation

// Persisted as JSON. Every field added later MUST be optional (or decoded with a default): a decode failure renames history.json to .bak and starts empty, which silently wipes the user's history on upgrade.
struct DictationEntry: Codable, Identifiable, Equatable {
    enum Mode: String, Codable { case batch, streaming }
    enum Status: String, Codable { case ok, failed, interrupted, cancelled }
    let id: UUID
    let date: Date
    let duration: TimeInterval
    var rawText: String?
    var processedText: String?
    var engineUsed: String  // "parakeet" | "whisper:<model>"
    let mode: Mode
    var status: Status
    var errorMessage: String?  // set when status == .failed
    var audioFilename: String?  // nil once expired / never written

    // Best text available for display/copy: processed wins over raw.
    var displayText: String? { processedText?.isEmpty == false ? processedText : rawText }
}

struct HistoryStats: Equatable {
    let totalWords: Int
    let averageWPM: Double  // words over spoken duration, entries with text only
    let streakDays: Int  // consecutive calendar days with >= 1 entry, ending today
}

enum AudioRetention: String, Codable, CaseIterable, Identifiable {
    case never, day, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: return "Never"
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }
    // nil = keep no audio at all.
    var maxAge: TimeInterval? {
        switch self {
        case .never: return nil
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }
}
