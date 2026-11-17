import SiltaAppSupport

nonisolated struct AppLoadFailure: Error, Equatable, Sendable {
  let message: String
  let kind: AppReadError.Kind?
  let commands: [String]

  init(_ error: any Error) {
    if let failure = error as? Self {
      self = failure
    } else if let failure = error as? AppReadError {
      self.init(message: failure.message, kind: failure.kind, commands: failure.next)
    } else {
      self.init(message: "Couldn’t refresh Silta data.", kind: nil, commands: [])
    }
  }

  init(message: String, kind: AppReadError.Kind? = nil, commands: [String] = []) {
    self.message = message
    self.kind = kind
    self.commands = commands
  }
}
