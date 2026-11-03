/// The human's words authorizing an agent command, with secret content redacted.
package struct HumanApproval: Sendable {
  /// The agent that received the human's go-ahead.
  package let actor: ActorID

  /// Trimmed words suitable for storage; never the original secret-bearing quote.
  package let words: String
}
