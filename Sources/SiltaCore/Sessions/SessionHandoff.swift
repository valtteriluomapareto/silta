/// A claimed task and its workspace-scoped recovery command.
package struct SessionHandoff: Encodable, Sendable {
  /// The workspace needed to address this task.
  package let workspace: String
  /// The task reference within that workspace.
  package let ref: String
  /// Run with a handoff body on stdin; the actor must still hold the claim.
  package var command: String {
    workspaceCommand(
      "silta comment " + shellWord(ref) + " --kind handoff -F -", workspace: workspace)
  }
}
