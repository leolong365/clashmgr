import SwiftUI

/// 订阅列表页。
public struct SubscriptionsView: View {
    @EnvironmentObject private var state: AppState
    @State private var showAdd = false
    @State private var renameTarget: Subscription?
    @State private var renameText = ""
    @State private var deleteTarget: Subscription?

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if state.store.subscriptions.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        title: "还没有订阅",
                        message: "添加一个机场订阅地址，或从文件导入本地编配。",
                        actionTitle: "添加订阅",
                        action: { showAdd = true }
                    )
                } else {
                    List {
                        ForEach(state.store.subscriptions) { sub in
                            row(for: sub)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("订阅")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddSubscriptionView()
                    .environmentObject(state)
                    .environmentObject(state.settings)
            }
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    if let t = renameTarget {
                        state.rename(t, to: renameText)
                    }
                    renameTarget = nil
                }
            }
            .alert("删除订阅", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )) {
                Button("取消", role: .cancel) { deleteTarget = nil }
                Button("删除", role: .destructive) {
                    if let t = deleteTarget { state.delete(t) }
                    deleteTarget = nil
                }
            } message: {
                Text("「\(deleteTarget?.name ?? "")」及其本地配置文件将被移除。")
            }
        }
    }

    @ViewBuilder
    private func row(for sub: Subscription) -> some View {
        let isCurrent = state.store.currentID == sub.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.footnote)
                }
                Text(sub.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(sub.nodeCount) 节点")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(sub.isRemote ? sub.hostLabel : "本地配置")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let info = sub.userInfo?.asInfo, TrafficBar.isAvailable(info) {
                TrafficBar(info: info)
            }

            HStack(spacing: 10) {
                Text(Self.relative(sub.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if sub.isRemote {
                    Button("刷新") { state.refresh(sub) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .disabled(state.isBusy)
                }
                Button("设为当前") { state.select(sub) }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(isCurrent)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isCurrent { state.select(sub) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = sub
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                renameText = sub.name
                renameTarget = sub
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    /// 「3 分钟前」这类相对时间。
    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
