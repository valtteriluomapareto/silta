/// A committed task reference and status, with warnings from that mutation.
package struct TaskResult: Encodable, Sendable {
  /// The workspace-prefixed task reference.
  package let ref: String

  /// The committed status.
  package let status: String

  /// Diagnostics that contain no original secret content.
  package let warnings: [OutputWarning]

  private enum CodingKeys: String, CodingKey {
    case ref, status
  }
}
