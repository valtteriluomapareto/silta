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

extension WorkspaceSettings.CodingKeys {
  func gloss(in settings: WorkspaceSettings) throws -> String {
    switch self {
    case .proposals: try settings.proposals.gloss
    case .reviewGate: try settings.reviewGate.gloss
    case .archiveAfterDays: "days before closed tasks archive"
    case .staleDays: "days before docs are stale"
    }
  }
}
