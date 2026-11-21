import SiltaAppSupport
import SwiftUI

struct AppSidebar: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      workspaceMenu.padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
      List {
        Section {
          ForEach(AppRoute.allCases) { route in
            navigationRow(route)
          }.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
        Section {
          ForEach(model.visibleData?.map?.apps ?? [], id: \.slug) { app in
            Button {
              model.showApp(app.slug)
            } label: {
              HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(appColor(app.slug)).frame(
                  width: 8, height: 8
                )
                .frame(width: 16).accessibilityHidden(true)
                Text(app.slug).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(
                  app.slug)
                Text(
                  model.visibleData?.snapshot?.board.appOpenCounts[app.slug] ?? 0, format: .number
                )
                .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
              }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(.rect)
            }.buttonStyle(.plain)
          }.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        } header: {
          Overline("Apps").padding(.leading, 8)
        }
      }.listStyle(.sidebar).scrollContentBackground(.hidden).font(.system(size: 13))
        .environment(\.defaultMinListRowHeight, 28)
      if !claimed.isEmpty { claimedCard.padding(.horizontal, 10) }
      refreshFooter
    }.foregroundStyle(Color("Ink"))
      .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
  }

  private func navigationRow(_ route: AppRoute) -> some View {
    let selected = model.route == route
    return Button {
      model.navigate(to: route)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: route.symbol).frame(width: 16)
        Text(route.title).fontWeight(selected ? .semibold : .regular)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let count = count(route) {
          Text(count).font(.system(size: 11, weight: route == .mywork ? .bold : .regular))
            .monospacedDigit()
            .padding(.horizontal, route == .mywork ? 6 : 0).padding(.vertical, 1)
            .foregroundStyle(
              route == .mywork
                ? Color("Canvas") : selected ? Color("TideText") : Color("SecondaryInk")
            )
            .background(route == .mywork ? Color("AccentColor") : .clear, in: .capsule)
        }
      }.padding(.horizontal, 8).padding(.vertical, 7)
        .background(
          selected ? Color("AccentColor").opacity(0.08) : .clear, in: .rect(cornerRadius: 10)
        )
        .contentShape(.rect)
    }.buttonStyle(.plain)
      .foregroundStyle(selected ? Color("TideText") : Color("Ink"))
      .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var claimedCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Overline("Claimed now")
      ForEach(claimed.prefix(SidebarContent.claimLimit), id: \.ref) { task in
        Button {
          model.inspect(task: task.ref)
        } label: {
          HStack(spacing: 8) {
            ActorLabel(actor: task.claimedBy ?? "").labelStyle(.iconOnly)
            Text(SidebarContent.claimTitle(task)).font(.system(size: 11, design: .monospaced))
              .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let age = SidebarContent.claimAge(task, now: model.now()) {
              Text(age).font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
            }
          }.contentShape(.rect)
        }.buttonStyle(.plain)
          .help(SidebarContent.claimSubtitle(task, now: model.now()))
          .accessibilityLabel(
            SidebarContent.claimTitle(task) + ", "
              + SidebarContent.claimSubtitle(task, now: model.now()))
      }
      if claimed.count > SidebarContent.claimLimit {
        Button("\(claimed.count - SidebarContent.claimLimit) more on the Board") {
          model.navigate(to: .board)
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color("TideText"))
      }
    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
      .seaPane(radius: 12)
  }

  private var workspaceMenu: some View {
    let name = model.data?.workspaces.first { $0.slug == model.workspace }?.name ?? "Workspace"
    return HStack(spacing: 10) {
      Text(String(name.prefix(1)).uppercased()).font(.system(size: 13, weight: .bold))
        .foregroundStyle(Color("Canvas")).frame(width: 28, height: 28)
        .background(Color("AccentColor"), in: .rect(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 1) {
        Menu(name) {
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
        }.menuStyle(.borderlessButton).font(.system(size: 13, weight: .semibold))
          .fixedSize()
          .accessibilityLabel("Workspace: " + name).help("Choose workspace")
          .disabled(model.data?.workspaces.isEmpty != false)
        if let map = model.visibleData?.map {
          Text("\(map.apps.count) apps · \(map.services.count) services")
            .font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(8).seaPane(radius: 12)
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

  private func appColor(_ slug: String) -> Color {
    Color(
      SidebarContent.appColor(slug: slug, apps: model.visibleData?.map?.apps ?? [])
        ?? SidebarContent.appColor(index: 0))
  }

  private var claimed: [AppTask] {
    model.visibleData?.snapshot?.board.doing.filter { $0.claimedBy != nil } ?? []
  }

  private func count(_ route: AppRoute) -> String? {
    guard let snapshot = model.visibleData?.snapshot else { return nil }
    switch route {
    case .mywork: return String(snapshot.work.waitingCount)
    case .workspace: return nil
    case .docs:
      return SidebarContent.documentCount(model.documentCatalog, stale: model.catalogFailure != nil)
    case .board:
      return String(
        snapshot.board.todo.count + snapshot.board.doing.count + snapshot.board.review.count)
    }
  }
}
