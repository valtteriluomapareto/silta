import Foundation
import Yams

struct Scenario: Decodable {
  var fixtures: Bool?
  var steps: [Step]

  /// Decodes strictly: a misspelled key must fail, not silently skip a check (§20.1).
  static func decode(_ yaml: String) throws -> Scenario {
    let root = try Yams.load(yaml: yaml)
    try checkKeys(root, allowed: ["fixtures", "steps"], at: "scenario")
    let steps = (root as? [AnyHashable: Any])?["steps"] as? [Any] ?? []
    for (index, step) in steps.enumerated() {
      try checkKeys(step, allowed: ["args", "cwd", "env", "expect"], at: "step \(index)")
      try checkKeys(
        (step as? [AnyHashable: Any])?["expect"], allowed: ["exit", "code", "stdout", "json"],
        at: "step \(index) expect")
    }
    return try YAMLDecoder().decode(Scenario.self, from: yaml)
  }

  private static func checkKeys(_ node: Any?, allowed: Set<String>, at place: String) throws {
    guard let mapping = node as? [AnyHashable: Any] else { return }
    let unknown = mapping.keys.map { "\($0)" }.filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else {
      let keys = unknown.joined(separator: ", ")
      throw ScenarioFailure(description: "Unknown key \(keys) in \(place)")
    }
  }

  struct Step: Decodable {
    var args: [String]
    var cwd: String?
    var env: [String: String]?
    var expect: Expectation
  }

  struct Expectation: Decodable {
    var exit: Int32
    var code: String?
    var stdout: String?
    var json: [String: Scalar]?
  }

  enum Scalar: Codable {
    case string(String)
    case integer(Int)
    case boolean(Bool)

    init(from decoder: any Decoder) throws {
      let value = try decoder.singleValueContainer()
      if let bool = try? value.decode(Bool.self) {
        self = .boolean(bool)
      } else if let int = try? value.decode(Int.self) {
        self = .integer(int)
      } else {
        self = .string(try value.decode(String.self))
      }
    }

    func encode(to encoder: any Encoder) throws {
      var value = encoder.singleValueContainer()
      switch self {
      case .string(let text): try value.encode(text)
      case .integer(let int): try value.encode(int)
      case .boolean(let bool): try value.encode(bool)
      }
    }
  }
}

struct ScenarioFailure: Error, CustomStringConvertible {
  var description: String
}
