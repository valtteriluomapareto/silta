/// Masked metadata for a document revision, independent of the selected body window.
package struct DocDisplayMetadata: Sendable {
  package let ref: String
  package let slug: String
  package let revision: Int
  package let title: String?
  package let kind: String?
  package let about: [String]?
  package let state: String
  package let archived: Bool
}

extension DocDisplayMetadata {
  var masked: Self {
    Self(
      ref: DocService.displayReference(ref), slug: DocService.displayReference(slug),
      revision: revision,
      title: title.map(DocService.preview), kind: kind.map(DocService.preview),
      about: about?.map(DocService.displayReference), state: state, archived: archived)
  }
}

extension DocService {
  static func displayMetadata(_ snapshot: DocRevision, archived: Bool) -> DocDisplayMetadata {
    DocDisplayMetadata(
      ref: "doc:\(snapshot.slug)@\(snapshot.revision)", slug: snapshot.slug,
      revision: snapshot.revision, title: snapshot.title, kind: snapshot.kind,
      about: snapshot.about, state: snapshot.state, archived: archived
    ).masked
  }
}
