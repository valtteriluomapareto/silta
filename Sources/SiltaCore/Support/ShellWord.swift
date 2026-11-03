import Foundation

/// Quotes one identifier as a literal shell argument in a recovery command.
func shellWord(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
