/// Supplied content and optional baseline/source selections for a pending revision.
package struct DocProposalRequest: Sendable {
  var slug: String
  var title: String?
  var about: [String]?
  var base: String?
  var task: String?
  var why: String?

  /// Names supplied content, optional metadata and its source task.
  package init(
    slug: String, title: String? = nil, about: [String]? = nil, base: String? = nil,
    task: String? = nil, why: String? = nil
  ) {
    self.slug = slug.hasPrefix("doc:") ? String(slug.dropFirst(4)) : slug
    self.title = title
    self.about = about
    self.base = base
    self.task = task
    self.why = why
  }
}
