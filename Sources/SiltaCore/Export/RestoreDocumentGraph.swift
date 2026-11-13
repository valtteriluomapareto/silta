/// Document graph validation before any restore mutation.
struct RestoreDocumentGraph {
  let tree: ExportSnapshot
  let documents: ExportDocumentSnapshot
  let slug: String

  func run() throws {
    throw ExportError.unsupported("document graph validation")
  }
}
