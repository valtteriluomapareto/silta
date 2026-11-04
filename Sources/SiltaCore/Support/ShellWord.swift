import Foundation

/// Quotes one identifier as a literal shell argument in a recovery command.
package func shellWord(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Inserts a workspace into an implemented Silta command's prefix.
package func workspaceCommand(_ command: String, workspace: String) -> String {
  command.replacingOccurrences(
    of: "silta ", with: "silta --ws " + shellWord(workspace) + " ",
    options: .anchored)
}
