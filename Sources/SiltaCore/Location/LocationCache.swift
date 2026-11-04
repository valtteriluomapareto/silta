import CryptoKit
import Foundation
import GRDB

/// Derived distance results; every operation gives up immediately on lock contention.
struct LocationCache {
  let path: String

  static func key(_ parts: [String]) -> String {
    SHA256.hash(data: Data(parts.joined(separator: "\0").utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  func read(key: String) -> LocationDistance? {
    do {
      var config = Configuration()
      config.readonly = true
      config.busyMode = .immediateError
      let queue = try DatabaseQueue(path: path, configuration: config)
      return try queue.read { db in
        guard
          let data = try Data.fetchOne(
            db,
            sql: "SELECT value FROM where_cache WHERE key=?", arguments: [key])
        else { return nil }
        return try JSONDecoder().decode(LocationDistance.self, from: data)
      }
    } catch { return nil }  // Derived state can always be recomputed.
  }

  func write(_ value: LocationDistance, key: String, location: String) {
    do {
      var config = Configuration()
      config.busyMode = .immediateError
      let queue = try DatabaseQueue(path: path, configuration: config)
      try queue.write { db in
        try db.execute(
          sql: """
            CREATE TABLE IF NOT EXISTS where_cache(
              path TEXT PRIMARY KEY, key TEXT NOT NULL, value BLOB NOT NULL)
            """)
        try db.execute(
          sql: """
            INSERT INTO where_cache(path,key,value) VALUES(?,?,?)
            ON CONFLICT(path) DO UPDATE SET key=excluded.key,value=excluded.value
            """, arguments: [location, key, try JSONEncoder().encode(value)])
      }
    } catch {}  // A cache failure cannot fail a location read.
  }
}
