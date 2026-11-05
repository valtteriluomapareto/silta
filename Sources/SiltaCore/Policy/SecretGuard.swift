/// Pure, pinned secret scanning and redaction. Callers decide whether a write is allowed.
package enum SecretGuard {
  /// Rule-set version; changes deliberately with detection behavior.
  package static let version = 3

  /// Body-free warning for a successful redacted write.
  package static let warning = OutputWarning(
    code: "secret_redacted", message: "Secret content was redacted.")

  /// Finds all supported secret forms, merging overlaps so no detected span is exposed.
  /// Whole placeholders are exempt in credential fields. Explicit credentials outrank refs.
  package static func matches(in text: String) -> [SecretMatch] {
    var candidates: [SecretMatch] = []
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
          text.matches(of: /\b(?:doc|app|topic):[A-Za-z0-9_.-]+/)
            .contains(where: {
              let identifier = $0.output.drop(while: { $0 != ":" }).dropFirst()
              return identifier.startIndex == match.range.lowerBound
                && identifier.endIndex == match.range.upperBound
            })
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
    var output = text
    for match in matches(in: text).reversed() {
      output.replaceSubrange(match.range, with: "[REDACTED:\(match.rule)]")
    }
    return output
  }

  private static var rules: [(String, Regex<Substring>)] {
    [
      (
        "private_key",
        /(?s)-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z0-9]+ )?PRIVATE KEY-----/
      ),
      ("azure_key", /(?i)\bAccountKey\s*=\s*(?:"[^"\r\n]+"|'[^'\r\n]+'|[^;\s]+)/),
      ("sas", /(?i)[?&]sig=(?:<[^<>\r\n]+>|[^&\s"']+)/),
      ("password", /(?i)\b(?:Password|Pwd)\s*=\s*(?:"[^"\r\n]+"|'[^'\r\n]+'|[^;\s]+)/),
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
      // Anthropic documents the `sk-ant-` prefix shared by its key kinds. A key kind and
      // version tag such as `api03` or `admin01` follows, then a base64url body that is
      // 95 characters in current keys; 80 or more keeps unknown kinds and leaves
      // fragments and prose alone.
      ("anthropic", /\bsk-ant-[a-z0-9]+-[A-Za-z0-9_-]{80,}/),
      ("jwt", /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}(?![A-Za-z0-9_-])/),
      ("hetu", /\b[0-9]{6}[+\-ABCDEFYXWVU][0-9]{3}[0-9A-Y]\b/),
    ]
  }

  private static func validIdentity(_ value: String) -> Bool {
    let digits = value.prefix(6) + value.dropFirst(7).prefix(3)
    guard let number = Int(digits), let control = value.last else { return false }
    return Array("0123456789ABCDEFHJKLMNPRSTUVWXY")[number % 31] == control
  }
}
