#if DEBUG
  import CoreFoundation
  import Foundation
  import SiltaAppSupport

  nonisolated enum ControlAction: Equatable {
    case navigate(AppRoute)
    case select(String)
    case toggleInspector
    case copyRef
    case copyCommand
    case refresh
  }

  nonisolated enum ControlRefusal: String, Error {
    case invalidRequest, staleRun, unknownSelection, unavailable, readFailed, superseded, copyFailed
  }

  nonisolated enum ControlOutcome: Equatable {
    case accepted, noop, refused(ControlRefusal)

    func response(run: String, sequence: Int) -> [String: Any] {
      var value: [String: Any] = ["version": 1, "run": run, "seq": sequence]
      switch self {
      case .accepted: value["outcome"] = "accepted"
      case .noop: value["outcome"] = "noop"
      case .refused(let reason):
        value["outcome"] = "refused"
        value["reason"] = reason.rawValue
      }
      return value
    }
  }

  nonisolated struct ControlRequest {
    let action: ControlAction

    init(data: Data, run: String, sequence: Int) throws(ControlRefusal) {
      guard data.count <= 16_384,
        let object = try? JSONSerialization.jsonObject(with: data),  // invalid wire data is refused
        var fields = object as? [String: Any],
        let canonical = try? JSONSerialization.data(  // reject noncanonical or duplicate fields
          withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
        canonical == data,
        Self.integer(fields.removeValue(forKey: "version")) == 1,
        Self.integer(fields.removeValue(forKey: "seq")) == sequence,
        let requestRun = fields.removeValue(forKey: "run") as? String
      else { throw .invalidRequest }
      guard run == requestRun else { throw .staleRun }
      action = try Self.action(fields)
    }

    private static func action(_ input: [String: Any]) throws(ControlRefusal) -> ControlAction {
      var fields = input
      let name = fields.removeValue(forKey: "action") as? String
      let action: ControlAction
      switch name {
      case "nav", "select":
        guard let screen = fields.removeValue(forKey: "screen") as? String,
          let route = AppRoute(rawValue: screen)
        else { throw .invalidRequest }
        if name == "nav" {
          action = .navigate(route)
        } else {
          guard route != .mywork, let ref = fields.removeValue(forKey: "ref") as? String,
            !ref.isEmpty, ref.utf8.count <= 512,
            !ref.contains(where: { $0.isWhitespace })
          else { throw .invalidRequest }
          if let view = fields.removeValue(forKey: "view") {
            guard route == .docs, let name = view as? String,
              AppDocumentView(rawValue: name) != nil
            else { throw .invalidRequest }
            action = .select(screen + ":" + ref + ":" + name)
          } else {
            action = .select(screen + ":" + ref)
          }
        }
      case "inspector.toggle": action = .toggleInspector
      case "copy.ref": action = .copyRef
      case "copy.command": action = .copyCommand
      case "refresh": action = .refresh
      default: throw .invalidRequest
      }
      guard fields.isEmpty else { throw .invalidRequest }
      return action
    }

    private static func integer(_ value: Any?) -> Int? {
      guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
      else { return nil }
      return Int(number.stringValue)
    }
  }
#endif
