import Foundation

/// Converts a requested follow-up into a representable UTC calendar day.
enum TaskFollowUp {
  static func day(_ raw: String?, at date: Date) throws -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let today = calendar.startOfDay(for: date)
    let value = raw ?? "7d"
    let target: Date
    if let match = value.wholeMatch(of: /([0-9]+)d/), let days = Int(match.1) {
      guard let lastDay = calendar.date(from: DateComponents(year: 9999, month: 12, day: 31)),
        let remaining = calendar.dateComponents([.day], from: today, to: lastDay).day,
        days <= remaining,
        let result = calendar.date(byAdding: .day, value: days, to: today),
        result >= today, result.timeIntervalSince1970.isFinite
      else { throw invalid }
      target = result
    } else {
      guard let match = value.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/),
        let year = Int(match.1), let month = Int(match.2), let day = Int(match.3), year > 0,
        let result = calendar.date(from: DateComponents(year: year, month: month, day: day)),
        calendar.component(.year, from: result) == year,
        calendar.component(.month, from: result) == month,
        calendar.component(.day, from: result) == day, result >= today
      else { throw invalid }
      target = result
    }
    let parts = calendar.dateComponents([.year, .month, .day], from: target)
    guard let year = parts.year, let month = parts.month, let day = parts.day,
      (1...9999).contains(year)
    else { throw invalid }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  private static var invalid: TaskError {
    .invalid("Use a present or future UTC YYYY-MM-DD day or a representable Nd interval.")
  }
}
