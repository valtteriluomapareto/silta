/// The body and optional metadata for one accepted document revision.
struct DocDraft: Sendable {
  var slug: String
  var body: String
  var title: String?
  var kind: String?
  var about: [String]?
  var message: String?

  init(slug: String, body: String) {
    self.slug = slug
    self.body = body
  }
}
