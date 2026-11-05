import CryptoKit
import Foundation
import SiltaCore

/// Owns only authenticated blocks, leaving every byte outside them intact.
struct AgentInstallPlan {
  struct Edit {
    let path: String
    let before: Data?
    let after: Data?
    let mode: UInt16
    let security: String
    let diff: String
    var change: AgentInstallResult.Change { .init(path: path, diff: diff) }
  }

  let edits: [Edit]
  let token: String

  init(files: AgentInstallFiles, claude: Bool, codex: Bool, uninstall: Bool, root: String) throws {
    let targets = try AgentInstallTarget.selected(claude: claude, codex: codex, root: root)
    var edits: [Edit] = []
    var fingerprint = Data((files.home + files.preview).utf8)
    for target in targets {
      let path = target.path
      let source = try files.read(path)
      let before = source.data, mode = source.mode, security = source.security
      let old = String(data: before ?? Data(), encoding: .utf8) ?? ""
      let after = try target.replace(
        old, existed: before != nil, uninstall: uninstall,
        refusal: { throw files.refusal(path, "edited or ambiguous ownership/configuration") })
      guard after.utf8.count <= AgentInstallFiles.maximumBytes else {
        throw files.refusal(path, "rendered file exceeds the 1 MiB readable limit")
      }
      fingerprint.append(Data(path.utf8))
      fingerprint.append(Data("\(mode):\(security):\(before?.count ?? -1):".utf8))
      fingerprint.append(before ?? Data())
      fingerprint.append(Data("\(after.count):".utf8))
      fingerprint.append(Data(after.utf8))
      if old != after {
        let keepEmpty = old.contains(":keep" + (path.hasSuffix(".toml") ? "\n" : " -->\n"))
        edits.append(
          Edit(
            path: path, before: before,
            after: after.isEmpty && !keepEmpty ? nil : Data(after.utf8), mode: mode,
            security: security,
            diff: try target.previewDiff(
              old, after,
              refusal: { throw files.refusal(path, "edited or ambiguous ownership/configuration") })
          ))
      }
    }
    self.edits = edits
    token = Self.hash(fingerprint)
  }

  static func difference(_ old: String, _ new: String) -> String {
    var prefix = 0
    let left = Array(old), right = Array(new)
    while prefix < min(left.count, right.count), left[prefix] == right[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < min(left.count, right.count) - prefix,
      left[left.count - suffix - 1] == right[right.count - suffix - 1]
    { suffix += 1 }
    let removed = String(left[prefix..<(left.count - suffix)])
    let added = String(right[prefix..<(right.count - suffix)])
    let diff = [("-", removed), ("+", added)].filter { !$0.1.isEmpty }.map { sign, text in
      text.split(separator: "\n", omittingEmptySubsequences: false).map { sign + $0 }
        .joined(separator: "\n")
    }.joined(separator: "\n")
    return diff
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

}
