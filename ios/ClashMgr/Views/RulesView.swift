import SwiftUI

/// 规则页：规则列表 + 规则测试。
public struct RulesView: View {
    @EnvironmentObject private var state: AppState

    @State private var search = ""
    @State private var showTester = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if let cfg = state.config {
                    if cfg.rules.isEmpty {
                        EmptyStateView(
                            icon: "list.bullet.rectangle",
                            title: "没有规则",
                            message: "该订阅未定义 rules 段。"
                        )
                    } else {
                        ruleList(cfg)
                    }
                } else {
                    EmptyStateView(
                        icon: "list.bullet.rectangle",
                        title: "没有可用的配置",
                        message: "先在「订阅」页添加并选中一个订阅。"
                    )
                }
            }
            .navigationTitle("规则")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showTester = true
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .disabled(state.config == nil)
                }
            }
            .safeAreaInset(edge: .top) {
                if let cfg = state.config, !cfg.rules.isEmpty {
                    SearchField(text: $search, placeholder: "搜索规则内容或目标")
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                        .background(.bar)
                }
            }
            .sheet(isPresented: $showTester) {
                RuleTesterView()
                    .environmentObject(state)
            }
        }
    }

    private func ruleList(_ cfg: MihomoConfig) -> some View {
        let filtered = cfg.rules.filter { r in
            if search.isEmpty { return true }
            return r.type.localizedCaseInsensitiveContains(search)
                || r.payload.localizedCaseInsensitiveContains(search)
                || r.target.localizedCaseInsensitiveContains(search)
        }

        return List {
            Section {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, rule in
                    HStack(spacing: 8) {
                        Text("\(idx + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 30, alignment: .trailing)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(rule.type)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(ruleColor(rule.type).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(ruleColor(rule.type))
                                if !rule.payload.isEmpty {
                                    Text(rule.payload)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                Text(rule.target)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if !rule.params.isEmpty {
                                    Text(rule.params.joined(separator: ","))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("共 \(filtered.count) 条\(search.isEmpty ? "" : "（已过滤，总计 \(cfg.rules.count)）")")
            }
        }
        .listStyle(.plain)
    }

    private func ruleColor(_ type: String) -> Color {
        let t = type.uppercased()
        if t == "MATCH" { return .purple }
        if t.hasPrefix("DOMAIN") { return .blue }
        if t.hasPrefix("IP") { return .teal }
        if t == "GEOIP" || t == "GEOSITE" { return .indigo }
        if t == "RULE-SET" { return .orange }
        if t == "PROCESS-NAME" || t == "PROCESS-PATH" { return .pink }
        return .gray
    }
}
