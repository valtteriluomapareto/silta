/// Pure, pinned secret scanning and redaction. Callers decide whether a write is allowed.
package enum SecretGuard {
  /// Rule-set version; changes deliberately with detection behavior.
  package static let version = 7

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

extension SecretGuard {
  private struct ArmourOpening {
    let label: Substring
    let range: Range<String.Index>
    let lineStart: String.Index
  }

  private static var armourMarkdownPrefix: Regex<Substring> {
    /[\p{Zs}\t\u{feff}]*(?:>[\p{Zs}\t\u{feff}]*|(?:[-+*]|[0-9]{1,9}[.)])[\p{Zs}\t\u{feff}]+)*/
  }

  private static func armourSpace(_ character: Character) -> Bool {
    character == "\u{feff}" || (character.isWhitespace && !character.isNewline)
  }

  private static func privateKeyMatches(in text: String, fieldStart: String.Index?) -> [SecretMatch]
  {
    let boundary =
      /(?:-----|---- )(BEGIN|END) ((?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?)(?:-----| ----)/
    var start: ArmourOpening?
    var matches: [SecretMatch] = []
    var cursor = text.startIndex
    var lineStart = cursor

    func appendUnfinished(_ opening: ArmourOpening, before limit: String.Index) {
      if let end = unfinishedEnd(opening, in: text, before: limit, fieldStart: fieldStart) {
        matches.append(SecretMatch(rule: "private_key", range: opening.range.lowerBound..<end))
      }
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

  private static func unfinishedEnd(
    _ opening: ArmourOpening, in text: String, before limit: String.Index,
    fieldStart: String.Index?
  ) -> String.Index? {
    let after = text[opening.range.upperBound..<limit]
    let suffix = after.prefix(while: { !$0.isNewline })
    let start =
      if let fieldStart, (opening.lineStart...opening.range.lowerBound).contains(fieldStart) {
        fieldStart
      } else {
        opening.lineStart
      }
    let before = text[start..<opening.range.lowerBound]
    let prefix = before.prefixMatch(of: armourMarkdownPrefix)?.output ?? before.prefix(0)
    let standalone =
      prefix.endIndex == before.endIndex && suffix.allSatisfy(armourSpace)
      && (suffix.endIndex == text.endIndex || suffix.endIndex < limit)
    let inline = inlineArmourEnd(suffix, label: opening.label, in: text)
    if let inline, !suffix[inline...].allSatisfy(armourSpace) { return inline }
    let end = armourRunEnd(
      after, openingPrefix: prefix, label: opening.label,
      minimumFirst: standalone ? 16 : 40, initialPayload: inline)
    return end ?? inline ?? (standalone ? suffix.endIndex : nil)
  }

  /// Ends at payload bytes so an enclosing quote and subsequent fields survive.
  private static func inlineArmourEnd(
    _ suffix: Substring, label: Substring, in text: String
  ) -> String.Index? {
    let boundary =
      suffix.prefixMatch(of: /(?:\\[^\r\n]|[^\\'"\x60\r\n])*/)?.output ?? suffix.prefix(0)
    var body = boundary.drop(while: armourSpace)
    if let annotation = body.prefixMatch(of: /\((?i:truncated|incomplete|cut off)\)/) {
      body = body[annotation.range.upperBound...].drop(while: armourSpace)
    }
    let single = /\\(?:r\\)?n/
    let double = /\\\\(?:r\\\\)?n/
    if body.prefixMatch(of: double) != nil {
      return escapedArmourEnd(nestedField(body), label: label, separator: double)
    }
    if body.prefixMatch(of: single) != nil {
      return escapedArmourEnd(body, label: label, separator: single)
    }

    guard let first = body.prefixMatch(of: /([A-Za-z0-9+\/]{40,})={0,2}/),
      isPayloadBoundary(body[first.range.upperBound...]),
      !isCommitSHA(first.1), !isWholeReferenceIdentifier(first.range, in: text)
    else { return nil }
    var end = first.range.upperBound
    let continuation = /[\p{Zs}\t]+([A-Za-z0-9+\/]{16,})={0,2}/
    while let chunk = body[end...].prefixMatch(of: continuation),
      isPayloadBoundary(body[chunk.range.upperBound...]),
      !isWholeReferenceIdentifier(chunk.1.startIndex..<chunk.1.endIndex, in: text)
    {
      end = chunk.range.upperBound
    }
    return end
  }

  /// Keeps the encoded delimiter and following fields outside the nested payload.
  private static func nestedField(_ body: Substring) -> Substring {
    var backslashes = 0
    var start = body.startIndex
    for index in body.indices {
      if body[index] == "\\" {
        if backslashes == 0 { start = index }
        backslashes += 1
      } else {
        if backslashes == 1, body[index] == "\"" || body[index] == "'" {
          return body[..<start]
        }
        backslashes = 0
      }
    }
    return body
  }

  private static func isPayloadBoundary(_ tail: Substring) -> Bool {
    // Sentence punctuation can precede a delimiter. A joined extension or query still
    // belongs to the surrounding token.
    let remainder = tail.drop(while: { ".:!?…".contains($0) })
    guard let first = remainder.first else { return true }
    return armourSpace(first) || "),;]}>»”’".contains(first)
  }

  private static func isCommitSHA(_ word: Substring) -> Bool {
    [40, 64].contains(word.utf8.count) && word.wholeMatch(of: /[A-Fa-f0-9]+/) != nil
  }

  private static func escapedArmourEnd(
    _ body: Substring, label: Substring, separator: Regex<Substring>
  ) -> String.Index? {
    let payload = /((?:[A-Za-z0-9+\/]|\\{1,3}\/)+)={0,2}/
    var start = body.startIndex
    var end: String.Index?
    var afterBlank = false
    var continuedHeader = false
    while let newline = body[start...].prefixMatch(of: separator) {
      let rest = body[newline.range.upperBound...]
      let next = rest.firstMatch(of: separator)?.range.lowerBound
      let line = rest[..<(next ?? rest.endIndex)]
      start = line.endIndex
      if line.allSatisfy(armourSpace) {
        afterBlank = true
        continuedHeader = false
        continue
      }
      if end == nil, continuedHeader || armourHeader(line, label: label) {
        continuedHeader = label.hasPrefix("SSH2 ") && line.hasSuffix(#"\\"#)
        continue
      }
      let tail = line.drop(while: armourSpace)
      if end != nil, label.hasPrefix("PGP "),
        let checksum = tail.prefixMatch(of: /=[A-Za-z0-9+\/]{4}/),
        tail[checksum.range.upperBound...].allSatisfy(armourSpace)
      {
        end = checksum.range.upperBound
        break
      }
      let minimum = end == nil || afterBlank ? 16 : 1
      guard let match = tail.prefixMatch(of: payload),
        match.1.utf8.lazy.filter({ $0 != 92 }).count >= minimum,
        end != nil || !isCommitSHA(match.1),
        next == nil
          ? isPayloadBoundary(tail[match.range.upperBound...])
          : tail[match.range.upperBound...].allSatisfy(armourSpace)
      else { break }
      end = match.range.upperBound
      afterBlank = false
    }
    return end
  }

  private static func continuesArmour(
    _ prefix: Substring, after blankPrefix: Substring, opening: Substring
  ) -> Bool {
    let quoteDepth = opening.count { $0 == ">" }
    guard prefix.count(where: { $0 == ">" }) == quoteDepth else { return false }
    func afterQuotes(_ value: Substring) -> Substring {
      guard let last = value.lastIndex(of: ">") else { return value }
      return value[value.index(after: last)...]
    }
    let listPrefix = afterQuotes(opening)
    guard !listPrefix.allSatisfy(armourSpace) else { return true }
    if blankPrefix == opening, prefix == opening { return true }
    return afterQuotes(prefix).prefix(while: armourSpace).count >= listPrefix.count
  }

  /// Reads contiguous armour and its format-specific preamble, retaining original indices.
  private static func armourRunEnd(
    _ body: Substring, openingPrefix: Substring, label: Substring, minimumFirst: Int,
    initialPayload: String.Index?
  ) -> String.Index? {
    var end = initialPayload
    var cursor = body.firstIndex(where: \.isNewline) ?? body.endIndex
    var continuedHeader = false
    var blankPrefix: Substring?
    while cursor < body.endIndex {
      let next = body.index(after: cursor)
      cursor = body[next...].firstIndex(where: \.isNewline) ?? body.endIndex
      let original = body[next..<cursor]
      let prefix = original.prefixMatch(of: armourMarkdownPrefix)?.output ?? original.prefix(0)
      let line = original[prefix.endIndex...]
      if line.isEmpty {
        continuedHeader = false
        blankPrefix = prefix
        continue
      }
      if let blankPrefix, !continuesArmour(prefix, after: blankPrefix, opening: openingPrefix) {
        break
      }
      if end == nil, continuedHeader || armourHeader(line, label: label) {
        continuedHeader = label.hasPrefix("SSH2 ") && line.last == "\\"
        continue
      }
      let payload = line.wholeMatch(of: /([A-Za-z0-9+\/]+)={0,2}[ \t]*/)
      if end == nil, let payload, isCommitSHA(payload.1) { break }
      let minimum = end == nil ? minimumFirst : (blankPrefix == nil ? 1 : 16)
      let checksum =
        end != nil && label.hasPrefix("PGP ")
        && line.wholeMatch(of: /=[A-Za-z0-9+\/]{4}[ \t]*/) != nil
      guard checksum || (payload?.1.utf8.count ?? 0) >= minimum else { break }
      blankPrefix = nil
      end = cursor
    }
    return end
  }

  private static func armourHeader(_ line: Substring, label: Substring) -> Bool {
    if label.hasPrefix("SSH2 ") {
      return line.prefixMatch(of: /(?:Version|Comment|MessageID|Hash|Charset):/) != nil
    }
    if label.hasPrefix("PGP ") {
      return line.prefixMatch(of: /(?:Version|MessageID|Hash|Charset):/) != nil
    }
    return line.prefixMatch(of: /(?:Proc-Type|DEK-Info):/) != nil
  }
}
