extension WorkspaceSettings.Proposals {
  var gloss: String {
    switch self {
    case .triage: "proposals wait for triage"
    case .ask: "ask in chat before adding a task"
    }
  }
}

extension WorkspaceSettings.ReviewGate {
  var gloss: String {
    switch self {
    case .none: "no gate"
    case .any: "warn if latest review requests changes"
    case .human: "human approval required before done"
    }
  }
}

extension WorkspaceSettings.AskAbout {
  var gloss: String {
    switch self {
    case .standard: "ask about scope, dependencies, public APIs and the short list"
    case .short: "ask only about what others see, deletes, irreversible steps, money"
    }
  }
}
