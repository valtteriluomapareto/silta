import Foundation

struct DocInputPolicy {
  let actor: ActorID
  let allowSecret: Bool
  let command: String

  func identity(_ text: String) throws {
    if !allowSecret, !SecretGuard.matches(in: text).isEmpty {
      throw SecretError(command: command, text: text)
    }
  }

  func identities(_ refs: [String], keeping old: [String]) throws {
    for ref in refs where !old.contains(where: { $0.utf8.elementsEqual(ref.utf8) }) {
      try identity(ref.removingPercentEncoding ?? ref)
    }
  }

  func checked(_ text: String, keeping old: String? = nil) throws -> (String, Bool) {
    if old.map({ text.utf8.elementsEqual($0.utf8) }) == true
      || allowSecret || SecretGuard.matches(in: text).isEmpty
    {
      return (text, false)
    }
    if actor.isHuman { throw SecretError(command: command, text: text) }
    return (SecretGuard.redacted(text), true)
  }

  func title(_ text: String, keeping old: String?) throws -> (String, Bool) {
    if old.map({ text.utf8.elementsEqual($0.utf8) }) == true { return (text, false) }
    try DocMetadata.checkTitle(text)
    let result = try checked(text)
    try DocMetadata.checkTitle(result.0)
    return result
  }
}
