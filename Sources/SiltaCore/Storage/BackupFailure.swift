/// Backup-specific failures contain phase information and fixed storage diagnostics.
enum BackupFailure: CodedError, Equatable {
  case destination
  case staging
  case detached
  case occupied
  case filesystem(StorageError)

  var code: ErrorCode { .env }
  var next: [String] { ["silta doctor"] }

  var message: String {
    switch self {
    case .destination:
      "Backup could not be completed because the backup directory could not be opened safely."
    case .staging:
      "Backup could not be completed because its temporary snapshot could not be prepared."
    case .detached:
      "Backup could not be completed because a snapshot directory changed. "
        + "Inspect the backup directory."
    case .occupied:
      "Backup could not be completed because an item already occupies the snapshot name."
    case .filesystem(.busy), .filesystem(.locked):
      "Backup could not be completed because the snapshot source remained locked."
    case .filesystem(let cause):
      "Backup could not be completed. " + cause.message
    }
  }
}
