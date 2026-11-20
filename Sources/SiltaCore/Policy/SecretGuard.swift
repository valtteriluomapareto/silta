/// Pure, pinned secret scanning and redaction. Callers decide whether a write is allowed.
package enum SecretGuard {
  /// Rule-set version; changes deliberately with detection behavior.
  package static let version = 5

  /// Body-free warning for a successful redacted write.
  package static let warning = OutputWarning(
    code: "secret_redacted", message: "Secret content was redacted.")

  /// Finds all supported secret forms, merging overlaps so no detected span is exposed.
  /// Whole placeholders are exempt in credential fields. Explicit credentials outrank refs.
  package static func matches(
    in text: String, armourFieldStart: String.Index? = nil
  ) -> [SecretMatch] {
    var candidates = privateKeyMatches(in: text, fieldStart: armourFieldStart)
    for (rule, pattern) in rules {
      for match in text.matches(of: pattern.wordBoundaryKind(.simple)) {
        let value = String(text[match.range])
        if ["password", "azure_key", "sas"].contains(rule),
          let rawValue = value.split(separator: "=", maxSplits: 1).last,
          rawValue.drop(while: { $0.isWhitespace }).wholeMatch(of: /["']?<[^<>\r\n]+>["']?/) != nil
        {
          continue
        }
        if rule == "jwt", value.split(separator: ".").contains("signature") { continue }
        if rule == "hetu", !validIdentity(value) { continue }
        if rule == "azure_pat", value.count == 52,
          isWholeReferenceIdentifier(match.range, in: text)
        {
          continue
        }
        candidates.append(SecretMatch(rule: rule, range: match.range))
      }
    }
    candidates.sort {
      if $0.range.lowerBound != $1.range.lowerBound {
        return $0.range.lowerBound < $1.range.lowerBound
      }
      if $0.range.upperBound != $1.range.upperBound {
        return $0.range.upperBound > $1.range.upperBound
      }
      return $0.rule < $1.rule
    }
    var covered: [SecretMatch] = []
    for candidate in candidates {
      if let previous = covered.last, candidate.range.lowerBound < previous.range.upperBound {
        covered[covered.count - 1] = SecretMatch(
          rule: previous.rule,
          range: previous.range
            .lowerBound..<max(previous.range.upperBound, candidate.range.upperBound))
      } else {
        covered.append(candidate)
      }
    }
    return covered
  }

  /// Replaces every covered span without changing surrounding Unicode text.
  package static func redacted(_ text: String) -> String {
    redacted(text, matches: matches(in: text))
  }

  static func redacted(
    _ text: String, matches: [SecretMatch], preservingLineFeeds: Bool = false
  ) -> String {
    var output = text
    for match in matches.reversed() {
      let breaks = preservingLineFeeds ? text[match.range].utf8.count { $0 == 10 } : 0
      output.replaceSubrange(
        match.range, with: match.replacement + String(repeating: "\n", count: breaks))
    }
    return output
  }

  private static var rules: [(String, Regex<Substring>)] {
    [
      (
        "azure_key",
        /(?i)\bAccountKey\s*=\s*(?:"[^"\r\n]+"|'[^'\r\n]+'|<[^<>\r\n]+>|[^;\s]+)[^;\s]*/
      ),
      ("sas", /(?i)[?&]sig=(?:<[^<>\r\n]+>|[^&\s"']+)[^&\s"']*/),
      (
        "password",
        /(?i)\b(?:Password|Pwd)\s*=\s*(?:"[^"\r\n]+"|'[^'\r\n]+'|<[^<>\r\n]+>|[^;\s]+)[^;\s]*/
      ),
      ("aws_key", /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/),
      ("github_pat", /\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82})\b/),
      // A legacy PAT is 52 lowercase letters and digits. A current PAT is 84
      // characters with the uppercase AZDO marker at position 76; a 75- or
      // 76-character prefix covers both readings of the documented position.
      (
        "azure_pat",
        /\b(?:[a-z0-9]{52}|[A-Za-z0-9]{75}AZDO[A-Za-z0-9]{5}|[A-Za-z0-9]{76}AZDO[A-Za-z0-9]{4})\b/
      ),
      ("slack", /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/),
      ("google", /\bAIza[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])/),
      // Anthropic documents only the `sk-ant-` prefix its key kinds share. Current keys
      // follow it with a kind and version tag such as `api03-` and a 95-character
      // base64url body. Any 80 or more base64url characters after the prefix count, so
      // untagged or unknown kinds are caught while prose and fragments stay readable.
      // No leading word boundary: escaped newlines (`\nsk-ant-…`) and URL-encoded
      // assignments (`%3Dsk-ant-…`) put a word character right before the prefix.
      ("anthropic", /sk-ant-[A-Za-z0-9_-]{80,}/),
      ("jwt", /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}(?![A-Za-z0-9_-])/),
      ("hetu", /\b[0-9]{6}[+\-ABCDEFYXWVU][0-9]{3}[0-9A-Y]\b/),
    ]
  }

  private struct ArmourOpening {
    let label: Substring
    let range: Range<String.Index>
    let lineStart: String.Index
  }

  private static var armourMarkdownPrefix: Regex<Substring> {
    /[ \t]*(?:>[ \t]*|(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)*/
  }

  private static func privateKeyMatches(in text: String, fieldStart: String.Index?) -> [SecretMatch]
  {
    let boundary =
      /(?:-----|---- )(BEGIN|END) ((?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?)(?:-----| ----)/
    let prefix = armourMarkdownPrefix
    var start: ArmourOpening?
    var matches: [SecretMatch] = []
    var cursor = text.startIndex
    var lineStart = cursor

    func appendUnfinished(_ opening: ArmourOpening, before limit: String.Index) {
      let after = text[opening.range.upperBound..<limit]
      let suffix = after.prefix(while: { !$0.isNewline })
      let start =
        if let fieldStart, (opening.lineStart...opening.range.lowerBound).contains(fieldStart) {
          fieldStart
        } else {
          opening.lineStart
        }
      guard text[start..<opening.range.lowerBound].wholeMatch(of: prefix) != nil,
        suffix.allSatisfy({ $0 == " " || $0 == "\t" }),
        suffix.endIndex == text.endIndex || suffix.endIndex < limit
      else { return }
      let end = armourRunEnd(after)
      matches.append(SecretMatch(rule: "private_key", range: opening.range.lowerBound..<end))
    }

    for marker in text.matches(of: boundary) {
      if let newline = text[cursor..<marker.range.lowerBound].lastIndex(where: \.isNewline) {
        lineStart = text.index(after: newline)
      }
      cursor = marker.range.upperBound
      if marker.1 == "BEGIN" {
        if let start { appendUnfinished(start, before: marker.range.lowerBound) }
        start = ArmourOpening(label: marker.2, range: marker.range, lineStart: lineStart)
      } else if let current = start, marker.2 == current.label {
        matches.append(
          SecretMatch(
            rule: "private_key", range: current.range.lowerBound..<marker.range.upperBound))
        start = nil
      }
    }
    if let start { appendUnfinished(start, before: text.endIndex) }
    return matches
  }

  /// Accepts armour and metadata after an unfinished opener, retaining original indices.
  private static func armourRunEnd(_ body: Substring) -> String.Index {
    let content = /(?:[A-Za-z0-9+\/]+={0,2}|=[A-Za-z0-9+\/]{4})[ \t]*/
    let header = /(?:Version|Comment|MessageID|Hash|Charset|Proc-Type|DEK-Info):/
    let prefix = armourMarkdownPrefix
    var end = body.firstIndex(where: \.isNewline) ?? body.endIndex
    var cursor = end
    var continuedHeader = false
    while cursor < body.endIndex {
      let next = body.index(after: cursor)
      cursor = body[next...].firstIndex(where: \.isNewline) ?? body.endIndex
      let original = body[next..<cursor]
      let line = original[(original.prefixMatch(of: prefix)?.range.upperBound ?? next)...]
      if line.isEmpty {
        // A blank separator belongs to the block only if more armour follows.
        continuedHeader = false
        continue
      }
      let isHeader = continuedHeader || line.prefixMatch(of: header) != nil
      guard isHeader || line.wholeMatch(of: content) != nil else { break }
      continuedHeader = isHeader && line.last == "\\"
      end = cursor
    }
    return end
  }

  /// The ambiguous legacy token can be a complete typed identifier. Opaque paths, URLs,
  /// and longer encoded identifiers still go through the secret rules.
  private static func isWholeReferenceIdentifier(
    _ range: Range<String.Index>, in text: String
  ) -> Bool {
    let start =
      text[..<range.lowerBound].lastIndex(where: \.isWhitespace)
      .map { text.index(after: $0) } ?? text.startIndex
    let end = text[range.upperBound...].firstIndex(where: \.isWhitespace) ?? text.endIndex
    let raw = text[start..<end].drop(while: { #"'"`([{<"#.contains($0) })
    guard let last = raw.lastIndex(where: { !#"'"`)]}>.,;"#.contains($0) }) else { return false }
    let ref = raw[...last]
    func whole(_ part: Substring) -> Bool {
      part.startIndex == range.lowerBound && part.endIndex == range.upperBound
    }

    if let named = ref.wholeMatch(of: /(?:doc|app|topic|ext|service):([A-Za-z0-9_.%-]+)/) {
      return whole(named.1)
    }
    if let document = ref.wholeMatch(of: /doc:([A-Za-z0-9_-]+)@[1-9][0-9]*(?:\/[1-9][0-9]*)?/) {
      return whole(document.1)
    }
    let edgePattern = /edge:([A-Za-z0-9_-]+)\/(?:service:)?([A-Za-z0-9_%-]+)\/([A-Za-z0-9_%-]+)/
    if let edge = ref.wholeMatch(of: edgePattern) {
      return whole(edge.1) || whole(edge.2) || whole(edge.3)
    }
    let taskPattern = /(?:task:)?([A-Za-z0-9_-]+)-([1-9][0-9]*)(?:\/([1-9][0-9]*))?/
    if let task = ref.wholeMatch(of: taskPattern) {
      return whole(task.1) && Int64(task.2) != nil && (task.3.map { Int64($0) != nil } ?? true)
    }
    let code = ref.hasPrefix("code:") ? ref.dropFirst(5) : ref
    guard code.startIndex == range.lowerBound, code.contains(":") else { return false }
    let owner = try? TaskLinkTarget.storedCodeApp(String(code))  // Non-code text stays scanable.
    return owner.map { $0 == text[range] } ?? false
  }

  private static func validIdentity(_ value: String) -> Bool {
    let digits = value.prefix(6) + value.dropFirst(7).prefix(3)
    guard let number = Int(digits), let control = value.last else { return false }
    return Array("0123456789ABCDEFHJKLMNPRSTUVWXY")[number % 31] == control
  }
}
