import SiltaAppSupport
import SwiftUI

struct AppSidebar: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      workspaceMenu.padding(.horizontal, 18).padding(.vertical, 12)
      List {
        Section {
          ForEach(AppRoute.allCases) { route in
            Button {
              model.navigate(to: route)
            } label: {
              HStack(spacing: 9) {
                Image(systemName: route.symbol).frame(width: 16)
                Text(route.title).frame(maxWidth: .infinity, alignment: .leading)
                if let count = count(route) {
                  Text(count).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(
                      model.route == route ? Color("TideText") : Color("SecondaryInk"))
                }
              }.padding(.horizontal, 8).padding(.vertical, 6)
                .background(
                  model.route == route ? Color("TideText").opacity(0.12) : .clear,
                  in: .rect(cornerRadius: 8)
                )
                .contentShape(.rect)
            }.buttonStyle(.plain)
              .foregroundStyle(model.route == route ? Color("TideText") : Color("Ink"))
          }.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
        Section("Apps") {
          ForEach(Array((model.visibleData?.map?.apps ?? []).enumerated()), id: \.element.slug) {
            index, app in
            Button {
              model.showApp(app.slug)
            } label: {
              HStack(spacing: 9) {
                StatusDot(color: Color(SidebarContent.appColor(index: index))).frame(width: 16)
                Text(app.slug).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(
                  app.slug)
                Text(
                  model.visibleData?.snapshot?.board.appOpenCounts[app.slug] ?? 0, format: .number
                )
                .font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
              }.padding(.vertical, 4).contentShape(.rect)
            }.buttonStyle(.plain)
          }
        }
        Section("Claimed now") {
          ForEach(claimed, id: \.ref) { task in
            Button {
              model.inspect(task: task.ref)
            } label: {
              HStack(spacing: 9) {
                ActorLabel(actor: task.claimedBy ?? "").labelStyle(.iconOnly).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                  Text(SidebarContent.claimTitle(task)).font(.system(size: 12)).lineLimit(1)
                  Text(SidebarContent.claimSubtitle(task, now: model.now()))
                    .font(.system(size: 11)).foregroundStyle(Color("SecondaryInk")).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.padding(.vertical, 4).contentShape(.rect)
            }.buttonStyle(.plain)
          }
        }
      }.listStyle(.sidebar).font(.system(size: 13))
        .environment(\.defaultMinListRowHeight, 28)
      refreshFooter
    }.foregroundStyle(Color("Ink"))
      .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
  }

  private var workspaceMenu: some View {
    let name = model.data?.workspaces.first { $0.slug == model.workspace }?.name ?? "Workspace"
    return Menu {
      ForEach(model.data?.workspaces ?? [], id: \.slug) { workspace in
        Button {
          model.selectWorkspace(workspace.slug)
        } label: {
          if model.workspace == workspace.slug {
            Label(workspace.name, systemImage: "checkmark")
          } else {
            Text(workspace.name)
          }
        }
      }
    } label: {
      HStack(spacing: 9) {
        Text(String(name.prefix(1)).uppercased()).font(.system(size: 11, weight: .bold))
          .foregroundStyle(.white).frame(width: 22, height: 22)
          .background(Color("TideText"), in: .rect(cornerRadius: 6))
        Text(name).font(.system(size: 13, weight: .semibold))
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(
          Color("SecondaryInk"))
      }.contentShape(.rect)
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).help("Choose workspace")
      .disabled(model.data?.workspaces.isEmpty != false)
  }

  private var refreshFooter: some View {
    TimelineView(.periodic(from: .now, by: 60)) { _ in
      let checkedAt = model.visibleData?.checkedAt
      let stale = checkedAt.map { model.now().timeIntervalSince($0) >= 60 } ?? true
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          if model.isLoading {
            ProgressView().controlSize(.mini).frame(width: 8)
          } else {
            StatusDot(
              color: Color(
                model.failure != nil ? "AttentionMarker" : stale ? "Warning" : "Success"))
          }
          Text(
            SidebarContent.refreshText(
              loading: model.isLoading, failure: model.failure != nil, checkedAt: checkedAt,
              now: model.now())
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          if !model.isLoading && (stale || model.failure != nil) {
            Button(model.failure == nil ? "Refresh" : "Retry") { model.refresh(force: true) }
              .buttonStyle(.plain).foregroundStyle(Color("TideText"))
          }
        }
        if let failure = model.failure {
          Text(
            failure.message
              + (checkedAt.map {
                " · showing data from " + $0.formatted(date: .omitted, time: .shortened)
              } ?? "")
          )
          .foregroundStyle(Color("SecondaryInk")).lineLimit(2).help(failure.message)
        }
      }.font(.system(size: 11)).padding(18)
        .background(model.failure == nil ? .clear : Color("AttentionMarker").opacity(0.08))
    }
  }

  private var claimed: [AppTask] {
    model.visibleData?.snapshot?.board.doing.filter { $0.claimedBy != nil } ?? []
  }

  private func count(_ route: AppRoute) -> String? {
    guard let snapshot = model.visibleData?.snapshot else { return nil }
    switch route {
    case .mywork: return String(snapshot.work.waitingCount)
    case .workspace: return nil
    case .docs: return SidebarContent.documentCount(model.documentCatalog)
    case .board:
      return String(
        snapshot.board.todo.count + snapshot.board.doing.count + snapshot.board.review.count)
    }
  }
}
