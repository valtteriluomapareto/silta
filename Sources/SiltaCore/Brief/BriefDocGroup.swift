/// A bounded document preview for one map target.
struct BriefDocGroup: Equatable, Sendable {
  let ref: String
  let workspace: String
  let total: Int
  let rows: [String]
}
