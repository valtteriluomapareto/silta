import Foundation

nonisolated enum RelativeAge {
  static func text(_ timestamp: String?, now: Date) -> String? {
    guard let timestamp else { return nil }
    let date: Date
    do {
      date = try Date(
        timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    } catch {
      return nil
    }
    let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60) min ago" }
    if seconds < 86400 { return "\(seconds / 3600) h ago" }
    return "\(seconds / 86400) d ago"
  }

}
