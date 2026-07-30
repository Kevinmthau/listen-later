import Foundation

extension TimeInterval {
    var queueTimestamp: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let seconds = Int(self.rounded(.down))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    var queueCompactDuration: String {
        guard isFinite, self > 0 else { return "0 min" }
        let totalMinutes = max(1, Int((self / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 {
            return "\(hours) hr \(minutes) min"
        }
        if hours > 0 {
            return "\(hours) hr"
        }
        return "\(minutes) min"
    }
}

