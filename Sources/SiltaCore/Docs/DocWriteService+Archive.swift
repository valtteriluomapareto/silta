extension DocWriteService {
  func archive(_ ref: String) throws -> DocWriteResult {
    throw DocError.invalid("Document archive is unavailable.")
  }
}
