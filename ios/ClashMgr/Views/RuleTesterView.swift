import SwiftUI

/// 规则测试：输入域名或 URL，看会命中哪条规则、最终走哪个策略组。
public struct RuleTesterView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""

    public init() {}

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("例如 github.com 或 https://x.com/a", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("待测目标")
                } footer: {
                    Text("支持域名、IP、完整 URL。按 mihomo 的规则顺序逐条匹配，命中即停。")
                }

                if !trimmedInput.isEmpty {
                    if let cfg = state.config,
                       let parsed = RuleMatcher.inferInput(trimmedInput) {
                        let result = RuleMatcher.test(parsed, rules: cfg.rules)
                        resultSections(result, parsed: parsed)
                    } else {
                        Section {
                            Text("无法识别为域名、IP 或 URL，请输入合法目标。")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("规则测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ result: RuleTestResult, parsed: RuleTestInput) -> some View {
        Section("结论") {
            HStack {
                Text("走向")
                Spacer()
                Text(outcomeLabel(result))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(result.matchedRule == nil ? Color.secondary : Color.accentColor)
            }

            HStack {
                Text("解析为")
                Spacer()
                Text(kindLabel(parsed) + " · " + parsed.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let r = result.matchedRule {
                HStack {
                    Text("规则序号")
                    Spacer()
                    Text(result.matchedIndex.map { "#\($0 + 1)" } ?? "—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("类型")
                    Spacer()
                    Text(r.type)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(r.line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }

        if !result.skipped.isEmpty {
            Section {
                ForEach(result.skipped, id: \.index) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.rule.line)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(2)
                        Text(item.reason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("跳过的规则（\(result.skipped.count)）")
            } footer: {
                Text("本 App 不加载 GeoIP / GeoSite / Rule-Set 数据库，这些规则无法离线判定，已跳过继续向后匹配。")
            }
        }
    }

    private func outcomeLabel(_ result: RuleTestResult) -> String {
        guard let target = result.matchedRule?.target, !target.isEmpty else {
            return "未命中"
        }
        return result.viaFallback ? "\(target)（MATCH 兜底）" : target
    }

    private func kindLabel(_ parsed: RuleTestInput) -> String {
        switch parsed.kind {
        case .domain: return "域名"
        case .ipAddress: return "IP 地址"
        case .url: return "URL"
        }
    }
}
