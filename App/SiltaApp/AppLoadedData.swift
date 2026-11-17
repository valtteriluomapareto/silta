import Foundation
import SiltaAppSupport

nonisolated struct AppLoadedData: Equatable, Sendable {
  let workspaces: [AppWorkspace]
  let workspace: String?
  let snapshot: AppSnapshot?
  let map: AppWorkspaceMap?
  let version: Int
  let checkedAt: Date
}
