import Foundation

struct LocationDistance: Codable {
  let app: String?
  let confidence: String
  let ranked: [String]

  static func choose(_ scores: [(String, Int)]) -> Self {
    let sorted = scores.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
    guard let best = sorted.first else { return Self(app: nil, confidence: "low", ranked: []) }
    let high = sorted.count == 1 || best.1 < sorted[1].1 - best.1
    return Self(
      app: high ? best.0 : nil, confidence: high ? "high" : "low", ranked: sorted.map(\.0))
  }
}
