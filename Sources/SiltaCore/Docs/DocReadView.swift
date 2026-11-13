enum DocReadView {
  case body
  case diff
  case comments(offset: Int, limit: Int)
  case comment(Int)

  var flags: String {
    switch self {
    case .body, .comment: ""
    case .diff: " --diff"
    case .comments(let offset, let limit): " --comments --offset \(offset) --limit \(limit)"
    }
  }

  static func parse(_ ref: String, diff: Bool, comments: Bool, offset: Int?, limit: Int?) throws
    -> (ref: String, view: Self)
  {
    let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 2, !(diff && comments),
      comments || (offset == nil && limit == nil),
      offset.map({ $0 >= 0 }) ?? true, limit.map({ (1...20).contains($0) }) ?? true
    else { throw usage("Use one read view; comment pages require --offset >= 0 and --limit 1-20.") }
    if parts.count == 2 {
      guard !diff, !comments, parts[0].contains("@"),
        let seq = Int(parts[1]), seq > 0, String(seq) == parts[1]
      else { throw usage("Use doc:slug@revision/comment for one comment, without view flags.") }
      return (String(parts[0]), .comment(seq))
    }
    return (
      ref, diff ? .diff : comments ? .comments(offset: offset ?? 0, limit: limit ?? 20) : .body
    )
  }

  private static func usage(_ message: String) -> UsageError {
    .usage(message: message, command: "silta doc show")
  }
}
