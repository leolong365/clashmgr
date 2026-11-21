import SwiftUI

/// 设置页。
public struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings

    @State private var showExport = false
    @State private var showAbout = false
    @State private var showClearConfirm = false
    @State private var uaDraft = ""
    @State private var testURLDraft = ""
    @State private var exportResult: Exporter.Result?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                subscriptionSection
                latencySection
                exportSection
                aboutSection
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showExport) {
                ExportView()
                    .environmentObject(state)
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
            .alert("清除缓存", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    state.clearLatencyResults()
                }
            } message: {
                Text("将清空所有已测得的延迟数据。订阅本身不受影响。")
            }
        }
    }

    // MARK: - 订阅

    private var subscriptionSection: some View {
        Section {
            HStack {
                Text("User-Agent")
                Spacer()
                TextField("clash.meta", text: $uaDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.secondary)
                    .onSubmit { settings.userAgent = uaDraft }
            }

            Picker("刷新周期", selection: Binding(
                get: { settings.refreshIntervalHours },
                set: { settings.refreshIntervalHours = $0 }
            )) {
                Text("不自动刷新").tag(0)
                Text("每 6 小时").tag(6)
                Text("每 12 小时").tag(12)
                Text("每 24 小时").tag(24)
                Text("每 72 小时").tag(72)
            }

            if let sub = state.currentSubscription {
                HStack {
                    Text("当前订阅")
                    Spacer()
                    Text(sub.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } header: {
            Text("订阅")
        } footer: {
            Text("User-Agent 决定机场返回的配置格式。若导入后节点为空，试试改为 clash 或 mihomo。")
        }
        .onAppear { uaDraft = settings.userAgent }
    }

    // MARK: - 测速

    private var latencySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("测速并发")
                    Spacer()
                    Text("\(settings.concurrency)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(settings.concurrency) },
                    set: { settings.concurrency = Int($0.rounded()) }
                ), in: 1...32, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("单节点超时")
                    Spacer()
                    Text(String(format: "%.0f 秒", settings.timeout))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { settings.timeout },
                    set: { settings.timeout = $0 }
                ), in: 1...15, step: 1)
            }

            HStack {
                Text("探测地址")
                Spacer()
                TextField("https://...", text: $testURLDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .foregroundStyle(.secondary)
                    .onSubmit { settings.latencyTestURL = testURLDraft }
            }

            Button {
                showClearConfirm = true
            } label: {
                Label("清除测速缓存", systemImage: "trash")
            }
            .foregroundStyle(.red)
        } header: {
            Text("测速")
        } footer: {
            Text("本 App 不建立隧道，测的是到节点服务器的 TCP 握手往返时间，用于判断节点是否可达。")
        }
        .onAppear { testURLDraft = settings.latencyTestURL }
    }

    // MARK: - 导出

    private var exportSection: some View {
        Section {
            Button {
                showExport = true
            } label: {
                Label("导出配置", systemImage: "square.and.arrow.up")
            }
            .disabled(state.config == nil)
        } header: {
            Text("导出")
        } footer: {
            Text("把当前订阅里挑选的节点导出成 YAML，可直接给电脑端 mihomo / Clash Verge 使用。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            Button {
                showAbout = true
            } label: {
                Label("关于", systemImage: "info.circle")
            }
            HStack {
                Text("版本")
                Spacer()
                Text(Self.appVersion)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// 关于页。
public struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(Color.accentColor)
                        Text("流量管家")
                            .font(.title3.weight(.semibold))
                        Text("v" + SettingsView.appVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .listRowBackground(Color.clear)
                }

                Section("这是什么") {
                    Text("一个 Mihomo / Clash 订阅管理工具。可以导入订阅、查看节点与策略组、测速、查询规则走向，并把挑好的节点导出成配置给电脑使用。")
                        .font(.footnote)
                }

                Section("它不做什么") {
                    Text("本 App 不包含 VPN 隧道，不接管系统流量，不修改任何系统网络设置。它只是一份配置阅读器与整理工具。")
                        .font(.footnote)
                }

                Section("数据与隐私") {
                    Text("所有数据都存在本机 App 沙盒内，不上传、不统计、不需要登录。仅在拉取订阅与测速时会主动访问你填写的地址。")
                        .font(.footnote)
                }

                Section("开源许可") {
                    Text("YAML 解析、规则匹配与导出逻辑为本项目自行实现，未使用第三方库。")
                        .font(.footnote)
                }
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
