/// The `--json` envelope (spec §16). Keys are snake_case and encoded sorted.
struct Envelope: Encodable {
  /// The envelope version; data shapes only gain fields under one version.
  static let version = 1

  /// Forwards to the command's data, whatever its type.
  struct AnyData: Encodable {
    let value: any Encodable

    func encode(to encoder: any Encoder) throws {
      try value.encode(to: encoder)
    }
  }

  let schema = Envelope.version
  let ok: Bool
  let data: AnyData?
  let error: EnvelopeFailure?
  let warnings: [OutputWarning]
}

/// The envelope's `error` object.
struct EnvelopeFailure: Encodable {
  let code: String
  let message: String
  let next: [String]
  let nextBy: String
  let retryAfter: Int?

  enum CodingKeys: String, CodingKey {
    case code, message, next
    case nextBy = "next_by"
    case retryAfter = "retry_after_s"
  }
}
