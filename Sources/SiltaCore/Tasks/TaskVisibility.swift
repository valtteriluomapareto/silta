import Foundation
import GRDB

/// Shared task visibility and date-based archive predicates for local backlog reads.
struct TaskVisibility {
  static let archiveSQL = """
    CASE WHEN task.archive_override IS NOT NULL THEN task.archive_override='archived'
    WHEN task.status NOT IN ('done','dropped') OR task.closed_at IS NULL THEN 0
    ELSE coalesce(silta_archive_instant(task.closed_at)<:archive_cutoff,-1) END
    """
  static let localSQL = """
    (task.status<>'proposed' OR :all_proposals OR task.created_by=:viewer)
    AND (task.external_ref IS NULL OR :promoted)
    """
  static let sql = """
    \(localSQL) AND (\(archiveSQL))=0
    """

  let arguments: StatementArguments

  init(
    actor: ActorID, at date: Date, days: Int, proposed: Bool = false,
    promoted: Bool = false
  ) {
    arguments = [
      "viewer": actor.description, "all_proposals": proposed || actor.isHuman,
      "promoted": promoted,
      "archive_cutoff": date.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970,
    ]
  }

  static func register(in db: Database) {
    db.add(
      function: DatabaseFunction("silta_archive_instant", argumentCount: 1, pure: true) { values in
        guard let value = values.first, let text = String.fromDatabaseValue(value) else {
          return nil
        }
        if let instant = canonicalInstant(text) { return instant }
        do {
          return try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(text).timeIntervalSince1970
        } catch { return nil }
      })
  }

  /// The instant of an in-range `YYYY-MM-DDTHH:MM:SS.mmmZ` timestamp, computed without a
  /// formatter so archive checks over large backlogs stay cheap. Other text, including
  /// years before 1600 where calendars may differ, returns nil
  /// and takes the lenient parser.
  static func canonicalInstant(_ text: String) -> Double? {
    var text = text
    return text.withUTF8 { canonicalInstant(bytes: $0) }
  }

  private static func canonicalInstant(bytes: UnsafeBufferPointer<UInt8>) -> Double? {
    guard bytes.count == 24, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
      bytes[13] == 0x3A, bytes[16] == 0x3A, bytes[19] == 0x2E, bytes[23] == 0x5A
    else { return nil }
    func number(_ range: Range<Int>) -> Int? {
      var value = 0
      for index in range {
        let digit = Int(bytes[index]) - 0x30
        guard (0...9).contains(digit) else { return nil }
        value = value * 10 + digit
      }
      return value
    }
    guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
      let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
      let millisecond = number(20..<23), year >= 1600, (1...12).contains(month), hour < 24,
      minute < 60, second < 60
    else { return nil }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...lengths[month - 1]).contains(day) else { return nil }
    // Days since 1970-01-01 in the proleptic Gregorian calendar.
    let shifted = month <= 2 ? year - 1 : year
    let era = shifted / 400
    let yearOfEra = shifted - era * 400
    let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    let days = era * 146_097 + dayOfEra - 719_468
    let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
    return Date(
      timeIntervalSinceReferenceDate: Double(seconds - 978_307_200) + Double(millisecond) / 1000
    ).timeIntervalSince1970
  }

  /// Counts done tasks in `scope` whose archive instant cannot be read; the visibility
  /// predicate already leaves them out.
  static func unreadableDates(scope: String, arguments: StatementArguments, in db: Database)
    throws -> Int
  {
    try Int.fetchOne(
      db,
      sql: """
        SELECT count(*) FROM task LEFT JOIN app ON app.id=task.app_id
          WHERE task.status='done' AND \(scope) AND \(localSQL) AND (\(archiveSQL))=-1
        """, arguments: arguments) ?? 0
  }

  static func isArchived(_ task: TaskDetails, at date: Date, days: Int, in db: Database) throws
    -> Bool
  {
    let value = try Int.fetchOne(
      db,
      sql: """
        SELECT \(archiveSQL) FROM (SELECT :choice AS archive_override,
          :status AS status,:closed AS closed_at) AS task
        """,
      arguments: [
        "choice": task.archiveOverride, "status": task.status,
        "closed": task.closedAt,
        "archive_cutoff": date.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970,
      ])
    guard let value, value >= 0 else { throw StorageError.unavailable }
    return value == 1
  }
}
