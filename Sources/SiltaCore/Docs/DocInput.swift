import Foundation

enum DocInput {
  static let maximumBytes = 64 * 1024

  static func read(nextBytes: (Int) throws -> Data?) throws -> String {
    ""
  }
}
