import SiltaAppSupport

extension [AppMapApp] {
  /// The display name of the app with this slug, or the slug when the map lacks the app.
  nonisolated func name(of slug: String) -> String { first { $0.slug == slug }?.name ?? slug }
}

extension AppWorkspaceMap {
  /// The display name of a connection endpoint: an app slug or a `service:` key. An endpoint
  /// the map lacks keeps its slug, without the `service:` prefix.
  nonisolated func endpointName(_ key: String) -> String {
    let prefix = "service:"
    guard key.hasPrefix(prefix) else { return apps.name(of: key) }
    return services.first { $0.key == key }?.name ?? String(key.dropFirst(prefix.count))
  }
}
