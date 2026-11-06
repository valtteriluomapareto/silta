import Foundation

/// A content seal detects edits without depending on the installed binary version.
struct AgentOwnedBlock {
  let outside: String
  let owned: Bool
  let span: String
  private let origin: String
  private let start: String
  private let end: String
  private let seal: String
  private let offset: Int

  init(_ original: String, existed: Bool, refusal: () throws -> Never) throws {
    start = "\n<!-- silta:begin "
    end = "<!-- silta:end -->\n"
    seal = " -->\n"
    var text = original
    var origin = existed ? "keep" : "new"
    var offset = text.count
    var hadOwnership = false
    var span = ""
    if let begin = text.range(of: start), let finish = text.range(of: end),
      begin.upperBound < finish.lowerBound,
      let header = text.range(of: seal, range: begin.upperBound..<finish.lowerBound)
    {
      let fields = text[begin.upperBound..<header.lowerBound].split(separator: ":")
      guard fields.count == 2, ["keep", "new"].contains(fields[1]) else { try refusal() }
      let owned = String(text[header.upperBound..<finish.lowerBound])
      origin = String(fields[1])
      guard AgentInstallPlan.hash(Data((origin + ":" + owned).utf8)) == fields[0] else {
        try refusal()
      }
      span = String(text[begin.lowerBound..<finish.upperBound])
      offset = text.distance(from: text.startIndex, to: begin.lowerBound)
      text.removeSubrange(begin.lowerBound..<finish.upperBound)
      hadOwnership = true
    }
    if text.contains("silta:begin") || text.contains("silta:end") { try refusal() }
    self.outside = text
    self.origin = origin
    self.offset = offset
    self.owned = hadOwnership
    self.span = span
  }

  func render(_ body: String) -> String {
    var text = outside
    let insertion = text.index(text.startIndex, offsetBy: offset)
    let block =
      start + AgentInstallPlan.hash(Data((origin + ":" + body).utf8)) + ":" + origin
      + seal + body + end
    text.insert(contentsOf: block, at: insertion)
    return text
  }
}
