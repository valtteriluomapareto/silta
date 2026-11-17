nonisolated struct ActorPresentation {
  let name: String
  let symbol: String
  let isCodex: Bool

  init(_ actor: String) {
    let parts = actor.split(separator: ":", maxSplits: 2).map(String.init)
    isCodex = parts.count == 3 && parts[0] == "agent" && parts[1] == "codex"
    if parts.count == 3, parts[0] == "agent", parts[1] == "claude" {
      name = "Claude"
      symbol = "asterisk"
    } else if isCodex {
      name = "Codex"
      symbol = "terminal"
    } else if parts.count == 2, parts[0] == "human" {
      name = parts[1]
      symbol = "person.fill"
    } else {
      name = actor
      symbol = "person.crop.circle"
    }
  }
}
