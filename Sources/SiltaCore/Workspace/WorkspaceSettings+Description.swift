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
  func value(in settings: WorkspaceSettings) throws -> BriefSettingValue {
    switch self {
    case .proposals: .string(try settings.proposals.rawValue)
    case .reviewGate: .string(try settings.reviewGate.rawValue)
    case .archiveAfterDays: .integer(try settings.archiveAfterDays)
    case .staleDays: .integer(try settings.staleDays)
    }
  }

  func gloss(in settings: WorkspaceSettings) throws -> String {
    switch self {
    case .proposals: try settings.proposals.gloss
    case .reviewGate: try settings.reviewGate.gloss
    case .archiveAfterDays: "days before closed tasks archive"
    case .staleDays: "days before docs are stale"
    }
  }
}
