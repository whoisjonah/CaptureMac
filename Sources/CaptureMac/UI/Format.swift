import Foundation

enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    static func precise(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        return String(format: "%d:%05.2f", minutes, clamped - Double(minutes * 60))
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func bufferLength(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        if seconds % 60 == 0 { return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
