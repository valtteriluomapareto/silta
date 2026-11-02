import Foundation

struct Scenario: Decodable {
  var fixtures: Bool?
  var steps: [Step]

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
