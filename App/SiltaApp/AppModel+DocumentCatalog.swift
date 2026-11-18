import SiltaAppSupport

extension AppModel {
  func loadDocumentCatalog(force: Bool) async throws {
    guard let reader, let workspace, let data = visibleData else { return }
    if !force, documentCatalog != nil, catalogWorkspace == workspace, catalogVersion == data.version
    {
      return
    }
    let page = try await Task.detached {
      try reader.documents(workspace: workspace, archived: true)
    }.value
    guard self.workspace == workspace, visibleData?.version == data.version else { return }
    documentCatalog = page
    catalogWorkspace = workspace
    catalogVersion = data.version
  }
}
