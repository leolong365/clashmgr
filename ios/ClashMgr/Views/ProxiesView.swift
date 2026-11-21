import SwiftUI
import UIKit

/// 代理页：策略组 + 全部节点。
public struct ProxiesView: View {
    @EnvironmentObject private var state: AppState

    private enum Scope: String, CaseIterable {
        case groups = "策略组"
        case allNodes = "全部节点"
    }

    @State private var scope: Scope = .groups
    @State private var search = ""
    @State private var typeFilter: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if state.config == nil {
                    EmptyStateView(
                        icon: "square.stack.3d.up.slash",
                        title: "没有可用的配置",
                        message: "先在「订阅」页添加并选中一个订阅。"
                    )
                } else {
                    content
                }
            }
            .navigationTitle("代理")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            state.testAllLatency()
                        } label: {
                            Label("全部测速", systemImage: "bolt.horizontal")
                        }
                        if let cfg = state.config, !cfg.proxies.isEmpty {
                            Button {
                                state.testAllLatency(nodes: visibleNodes(cfg.proxies))
                            } label: {
                                Label("仅测当前筛选", systemImage: "line.3.horizontal.decrease.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "bolt.horizontal")
                    }
                    .disabled(state.config == nil)
                }
            }
            .safeAreaInset(edge: .top) {
                if state.config != nil {
                    controlBar
                }
            }
            .overlay(alignment: .bottom) {
                if let p = state.latencyProgress {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("测速中 \(p.done)/\(p.total)")
                            .font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: - 控制栏

    private var controlBar: some View {
        VStack(spacing: 8) {
            Picker("范围", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)

            SearchField(text: $search, placeholder: "搜索节点或策略组")
                .padding(.horizontal)

            if scope == .allNodes, let cfg = state.config {
                typeChips(cfg.proxyTypes)
            }
        }
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func typeChips(_ types: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("全部", active: typeFilter == nil) { typeFilter = nil }
                ForEach(types, id: \.self) { t in
                    chip(t.uppercased(), active: typeFilter == t) {
                        typeFilter = (typeFilter == t) ? nil : t
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func chip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    active ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                    in: Capsule()
                )
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let cfg = state.config {
            switch scope {
            case .groups:
                groupList(cfg)
            case .allNodes:
                nodeList(cfg)
            }
        }
    }

    private func groupList(_ cfg: MihomoConfig) -> some View {
        let groups = cfg.groups.filter { g in
            search.isEmpty || g.name.localizedCaseInsensitiveContains(search)
        }
        if groups.isEmpty {
            return AnyView(EmptyStateView(
                icon: "square.stack.3d.up.slash",
                title: "没有策略组",
                message: search.isEmpty ? "该订阅未定义 proxy-groups。" : "没有匹配「\(search)」的策略组。"
            ))
        }
        return AnyView(List {
            ForEach(groups) { g in
                Section {
                    ForEach(cfg.flattenedMembers(of: g.name), id: \.self) { member in
                        memberRow(cfg, name: member)
                    }
                } header: {
                    groupHeader(cfg, g)
                }
            }
        }
        .listStyle(.insetGrouped))
    }

    private func groupHeader(_ cfg: MihomoConfig, _ g: ProxyGroup) -> some View {
        HStack(spacing: 6) {
            Text(g.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            if let t = g.groupType {
                Text(t.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .textCase(nil)
            }
            Spacer()
            Text("\(cfg.flattenedMembers(of: g.name).count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    @ViewBuilder
    private func memberRow(_ cfg: MihomoConfig, name: String) -> some View {
        let node = cfg.proxy(named: name)
        let ms = state.store.latencies[name]
        let failed = state.latencyFailures[name] != nil

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(1)
                if let n = node {
                    Text(n.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if MihomoConfig.isBuiltinTarget(name) {
                    Text("内置目标")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if cfg.group(named: name) != nil {
                    Text("策略组引用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            LatencyBadge(milliseconds: ms, failed: failed)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let n = node {
                Button {
                    state.testSingle(n)
                } label: {
                    Label("测试延迟", systemImage: "bolt")
                }
                Button {
                    UIPasteboard.general.string = n.name
                } label: {
                    Label("复制节点名", systemImage: "doc.on.doc")
                }
            }
        }
        .onTapGesture {
            if let n = node { state.testSingle(n) }
        }
    }

    private func nodeList(_ cfg: MihomoConfig) -> some View {
        let nodes = visibleNodes(cfg.proxies)
        if nodes.isEmpty {
            return AnyView(EmptyStateView(
                icon: "magnifyingglass",
                title: "没有匹配的节点",
                message: search.isEmpty ? "该订阅未定义 proxies。" : "换个关键词或清除筛选试试。"
            ))
        }
        return AnyView(List(nodes) { node in
            let ms = state.store.latencies[node.name]
            let failed = state.latencyFailures[node.name] != nil
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(node.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                LatencyBadge(milliseconds: ms, failed: failed)
            }
            .contentShape(Rectangle())
            .onTapGesture { state.testSingle(node) }
            .contextMenu {
                Button {
                    state.testSingle(node)
                } label: {
                    Label("测试延迟", systemImage: "bolt")
                }
                Button {
                    UIPasteboard.general.string = node.name
                } label: {
                    Label("复制节点名", systemImage: "doc.on.doc")
                }
            }
        }
        .listStyle(.plain))
    }

    /// 应用搜索与协议筛选。
    private func visibleNodes(_ nodes: [ProxyNode]) -> [ProxyNode] {
        nodes.filter { n in
            if let t = typeFilter, n.type.lowercased() != t.lowercased() { return false }
            if search.isEmpty { return true }
            return n.name.localizedCaseInsensitiveContains(search)
                || n.server.localizedCaseInsensitiveContains(search)
                || n.type.localizedCaseInsensitiveContains(search)
        }
    }
}
