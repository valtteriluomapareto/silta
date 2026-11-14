import Foundation

enum DocDiff {
  static func render(_ revision: DocRevision, base: DocRevision?) -> String {
    let ref = "doc:\(revision.slug)@\(revision.revision)"
    let oldRef = base.map { "doc:\($0.slug)@\($0.revision)" } ?? "(empty)"
    let header =
      "\(ref) [\(revision.state)] diff against \(oldRef)\n"
      + "actor: \(revision.actor)\ncreated_at: \(revision.createdAt)\n"
    let old = base.map(lines) ?? []
    let new = lines(revision)
    var prefix = 0
    while prefix < min(old.count, new.count), old[prefix].utf8.elementsEqual(new[prefix].utf8) {
      prefix += 1
    }
    var suffix = 0
    while suffix < min(old.count, new.count) - prefix,
      old[old.count - suffix - 1].utf8.elementsEqual(new[new.count - suffix - 1].utf8)
    {
      suffix += 1
    }
    let removed = old.count - prefix - suffix
    let added = new.count - prefix - suffix
    guard removed > 0 || added > 0 else { return header + "no visible changes\n" }
    return header + "--- \(oldRef)\n+++ \(ref)\n"
      + "@@ -\(removed == 0 ? prefix : prefix + 1),\(removed)"
      + " +\(added == 0 ? prefix : prefix + 1),\(added) @@\n"
      + old.dropFirst(prefix).prefix(removed).map { "-" + $0 + "\n" }.joined()
      + new.dropFirst(prefix).prefix(added).map { "+" + $0 + "\n" }.joined()
  }

  private static func lines(_ revision: DocRevision) -> [String] {
    let text =
      "title: \(revision.title ?? "(unknown)")\nkind: \(revision.kind ?? "(unknown)")\n"
      + "about: \(DocService.about(revision.about))\n"
      + DocService.evidence(revision) + "\n\(revision.body)"
    return SecretGuard.redacted(text).components(separatedBy: "\n")
  }
}
