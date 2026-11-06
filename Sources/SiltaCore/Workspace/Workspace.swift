/// An owned workspace identity and its serialized settings; independent of the database engine.
package struct Workspace: Codable, Equatable, Sendable {
  /// Local primary key, assigned on insertion.
  package var id: Int64?
  /// Stable export identity.
  package var uid: String
  /// Unique workspace slug.
  package var slug: String
  /// Display name.
  package var name: String
  /// Unique task display prefix.
  package var taskPrefix: String
  /// Serialized workspace settings.
  package var settings: String

  /// Creates an unsaved workspace without writing or validating external configuration.
  package init(uid: String, slug: String, name: String, taskPrefix: String, settings: String = "{}")
  {
    self.uid = uid
    self.slug = slug
    self.name = name
    self.taskPrefix = taskPrefix
    self.settings = settings
  }
}
