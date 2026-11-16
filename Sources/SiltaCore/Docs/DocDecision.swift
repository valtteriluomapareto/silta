/// Body-free terminal state of an existing proposal revision.
package struct DocDecision: Encodable, Sendable {
  package let ref: String
  package let state: String
}
