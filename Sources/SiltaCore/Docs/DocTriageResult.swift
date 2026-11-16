/// Receipts and attribution for a committed batch.
package struct DocTriageResult: Encodable, Sendable {
  package let docs: [DocDecision]
  package let workspace: String
  package let warnings: [OutputWarning]
  package let approvalUsed: Bool
  private enum CodingKeys: String, CodingKey { case docs }
}
