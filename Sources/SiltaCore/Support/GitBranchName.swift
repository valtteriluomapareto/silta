import Foundation

let gitBranchPrefix = "refs/heads/"

/// Strips Git's fixed ref prefix at the byte boundary, including before a combining mark.
func gitBranchName(in ref: String) -> String? {
  let prefix = gitBranchPrefix.utf8
  guard ref.utf8.starts(with: prefix), ref.utf8.count > prefix.count else { return nil }
  return String(bytes: ref.utf8.dropFirst(prefix.count), encoding: .utf8)
}
