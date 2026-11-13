/// Metadata and an explicit input mode for a human-authorized document edit.
package struct DocEditRequest {
  /// An identifier without a revision; a supplied doc: prefix is normalized at construction.
  package var slug: String
  /// One-line title; nil preserves an accepted title.
  package var title: String?
  /// Explicit kind; nil preserves an accepted kind or infers an initial kind.
  package var kind: String?
  /// Complete replacement attachment set; nil preserves the current live set.
  package var about: [String]?
  /// Explicit permission to retain detected new secret content under the human gate.
  package var allowSecret: Bool
  /// Copies the accepted owned body, mutually exclusive with supplied input.
  package var keepBody: Bool

  /// Captures metadata without input or storage I/O. Validation follows authorization.
  package init(
    slug: String, title: String? = nil, kind: String? = nil, about: [String]? = nil,
    allowSecret: Bool = false, keepBody: Bool = false
  ) {
    self.slug = slug.hasPrefix("doc:") ? String(slug.dropFirst(4)) : slug
    self.title = title
    self.kind = kind
    self.about = about
    self.allowSecret = allowSecret
    self.keepBody = keepBody
  }
}
