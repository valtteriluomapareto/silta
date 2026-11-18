import Foundation

nonisolated enum RelativeAge {
  /// The age of a timestamp. `short` drops "ago" for compact lists, such as "6 min".
  static func text(_ timestamp: String?, now: Date, short: Bool = false) -> String? {
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
    let suffix = short ? "" : " ago"
    if seconds < 3600 { return "\(seconds / 60) min" + suffix }
    if seconds < 86400 { return "\(seconds / 3600) h" + suffix }
    return "\(seconds / 86400) d" + suffix
  }

}
