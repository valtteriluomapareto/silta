#if DEBUG
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
    case invalidRequest, staleRun, unknownSelection, unavailable, readFailed, superseded
  }

  nonisolated enum ControlOutcome: Equatable {
    case accepted, copied(String), noop, refused(ControlRefusal)

    func response(run: String, sequence: Int) -> [String: Any] {
      var value: [String: Any] = ["version": 1, "run": run, "seq": sequence]
      switch self {
      case .accepted: value["outcome"] = "accepted"
      case .copied(let text):
        value["outcome"] = "accepted"
        value["copied"] = text
      case .noop: value["outcome"] = "noop"
      case .refused(let reason):
        value["outcome"] = "refused"
        value["reason"] = reason.rawValue
      }
      return value
    }
  }

  nonisolated struct ControlRequest {
    private enum Field: Decodable {
      case text(String), integer(Int)

      init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {  // a wire field may also be an integer
          self = .text(text)
        } else {
          self = .integer(try container.decode(Int.self))
        }
      }

      var text: String? {
        if case .text(let value) = self { return value }
        return nil
      }

      var integer: Int? {
        if case .integer(let value) = self { return value }
        return nil
      }
    }

    let action: ControlAction

    init(data: Data, run: String, sequence: Int) throws(ControlRefusal) {
      let decoder = JSONDecoder()
      guard data.count <= 16_384,
        String(data: data, encoding: .utf8) != nil,
        var fields = try? decoder.decode([String: Field].self, from: data),  // refuse invalid JSON
        (try? Self.uniqueKeys(in: data)) == true,  // refuse ambiguous member names
        fields.removeValue(forKey: "version")?.integer == 1,
        fields.removeValue(forKey: "seq")?.integer == sequence,
        let requestRun = fields.removeValue(forKey: "run")?.text
      else { throw .invalidRequest }
      guard run == requestRun else { throw .staleRun }
      action = try Self.action(fields)
    }

    private static func action(_ input: [String: Field]) throws(ControlRefusal) -> ControlAction {
      var fields = input
      let name = fields.removeValue(forKey: "action")?.text
      let action: ControlAction
      switch name {
      case "nav": action = .navigate(try screen(&fields))
      case "select": action = try selection(&fields)
      case "inspector.toggle": action = .toggleInspector
      case "copy.ref": action = .copyRef
      case "copy.command": action = .copyCommand
      case "refresh": action = .refresh
      default: throw .invalidRequest
      }
      guard fields.isEmpty else { throw .invalidRequest }
      return action
    }

    private static func screen(_ fields: inout [String: Field]) throws(ControlRefusal) -> AppRoute {
      guard let value = fields.removeValue(forKey: "screen")?.text,
        let route = AppRoute(rawValue: value)
      else { throw .invalidRequest }
      return route
    }

    private static func selection(_ fields: inout [String: Field]) throws(ControlRefusal)
      -> ControlAction
    {
      let route = try screen(&fields)
      guard route != .mywork, let ref = fields.removeValue(forKey: "ref")?.text,
        !ref.isEmpty, ref.utf8.count <= 512, !ref.contains(where: { $0.isWhitespace }),
        route != .docs || (ref.hasPrefix("doc:") && !ref.dropFirst(4).contains(":"))
      else { throw .invalidRequest }
      let value = route.rawValue + ":" + ref
      guard let view = fields.removeValue(forKey: "view") else { return .select(value) }
      guard route == .docs, let name = view.text, AppDocumentView(rawValue: name) != nil
      else { throw .invalidRequest }
      return .select(value + ":" + name)
    }

    /// The decoder validates a flat object. Scan its string tokens for members the
    /// keyed container would otherwise collapse, including escaped spellings.
    private static func uniqueKeys(in data: Data) throws -> Bool {
      var keys: Set<String> = []
      var opening: Data.Index?
      var escaped = false
      for (index, byte) in zip(data.indices, data) {
        if let start = opening {
          if escaped {
            escaped = false
            continue
          }
          if byte == 0x5C {
            escaped = true
            continue
          }  // backslash
          guard byte == 0x22 else { continue }
          opening = nil
          let next = data.suffix(from: data.index(after: index)).first {
            ![0x20, 0x09, 0x0A, 0x0D].contains($0)
          }
          if next == 0x3A {  // colon
            let key = try JSONDecoder().decode(String.self, from: data[start...index])
            if !keys.insert(key).inserted { return false }
          }
        } else if byte == 0x22 {
          opening = index
        }
      }
      return true
    }
  }
#endif
