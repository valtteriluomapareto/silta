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
  package var actor: String?
  package var createdAt: String?
  package var sourceTask: String?
  package var message: String?
  package var triagedBy: String?
  package var triagedAt: String?
}

extension DocDisplayMetadata {
  var masked: Self {
    Self(
      ref: DocService.displayReference(ref), slug: DocService.displayReference(slug),
      revision: revision,
      title: title.map(DocService.preview), kind: kind.map(DocService.preview),
      about: about?.map(DocService.displayReference), state: state, archived: archived,
      actor: actor.map(DocService.preview), createdAt: createdAt.map(DocService.preview),
      sourceTask: sourceTask.map(DocService.preview), message: message.map(DocService.preview),
      triagedBy: triagedBy.map(DocService.preview), triagedAt: triagedAt.map(DocService.preview))
  }
}

extension DocService {
  static func displayMetadata(_ snapshot: DocRevision, archived: Bool) -> DocDisplayMetadata {
    DocDisplayMetadata(
      ref: "doc:\(snapshot.slug)@\(snapshot.revision)", slug: snapshot.slug,
      revision: snapshot.revision, title: snapshot.title, kind: snapshot.kind,
      about: snapshot.about, state: snapshot.state, archived: archived,
      actor: snapshot.actor, createdAt: snapshot.createdAt, sourceTask: snapshot.sourceTask,
      message: snapshot.message, triagedBy: snapshot.triagedBy, triagedAt: snapshot.triagedAt
    ).masked
  }
}
