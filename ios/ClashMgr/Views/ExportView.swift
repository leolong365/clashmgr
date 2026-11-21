import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// 导出页：挑节点 → 生成 YAML → 复制 / 分享 / 二维码。
public struct ExportView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var keep: Set<String> = []
    @State private var includeRules = true
    @State private var search = ""
    @State private var generated: String?
    @State private var result: Exporter.Result?
    @State private var showShare = false
    @State private var shareURL: URL?

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if let cfg = state.config {
                    content(cfg)
                } else {
                    EmptyStateView(
                        icon: "square.and.arrow.up",
                        title: "没有可导出的配置",
                        message: "先在「订阅」页选中一个订阅。"
                    )
                }
            }
            .navigationTitle("导出配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成") { generate() }
                        .disabled(keep.isEmpty)
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = shareURL {
                    ShareSheet(items: [url])
                }
            }
            .onAppear { preselectAll() }
        }
    }

    @ViewBuilder
    private func content(_ cfg: MihomoConfig) -> some View {
        List {
            Section {
                HStack {
                    Button("全选") { keep = Set(cfg.proxies.map { $0.name }) }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("全不选") { keep.removeAll() }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text("已选 \(keep.count)/\(cfg.proxies.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Toggle("保留规则", isOn: $includeRules)

                SearchField(text: $search, placeholder: "筛选节点")
            }

            Section {
                ForEach(filteredNodes(cfg)) { node in
                    Button {
                        if keep.contains(node.name) {
                            keep.remove(node.name)
                        } else {
                            keep.insert(node.name)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: keep.contains(node.name)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(keep.contains(node.name)
                                                 ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(node.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("节点")
            }

            if let result = result, let text = generated {
                Section {
                    HStack {
                        Label("\(result.keptNodes) 个节点", systemImage: "checkmark.circle")
                        Spacer()
                        Text("\(byteCount(text))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if result.droppedMembers > 0 {
                        Text("清理了 \(result.droppedMembers) 处指向已排除节点的策略组引用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("复制 YAML", systemImage: "doc.on.doc")
                    }

                    Button {
                        saveAndShare(text)
                    } label: {
                        Label("分享文件", systemImage: "square.and.arrow.up")
                    }

                    NavigationLink("查看内容") {
                        Text(text)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .navigationTitle("YAML")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                } header: {
                    Text("结果")
                }

                Section {
                    if let qr = QRCode.image(from: text) {
                        HStack {
                            Spacer()
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 200, height: 200)
                            Spacer()
                        }
                    } else {
                        Text("配置过大，无法生成二维码。请用分享文件或复制。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("二维码")
                } footer: {
                    Text("电脑端可用 mihomo 客户端的「从二维码导入」。内容超过约 2 KB 时二维码会不完整，建议用文件分享。")
                }
            }
        }
    }

    private func filteredNodes(_ cfg: MihomoConfig) -> [ProxyNode] {
        guard !search.isEmpty else { return cfg.proxies }
        return cfg.proxies.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.server.localizedCaseInsensitiveContains(search)
                || $0.type.localizedCaseInsensitiveContains(search)
        }
    }

    private func preselectAll() {
        guard let cfg = state.config else { return }
        if keep.isEmpty {
            keep = Set(cfg.proxies.map { $0.name })
        }
    }

    private func generate() {
        guard let text = state.exportText(keepNodes: keep, includeRules: includeRules) else {
            return
        }
        generated = text
        if let cfg = state.config {
            result = Exporter().export(cfg, options: .init(
                keepNodeNames: keep,
                includeRules: includeRules
            ))
        }
    }

    private func saveAndShare(_ text: String) {
        guard let sub = state.currentSubscription else { return }
        let name = Exporter.exportFileName(subscriptionName: sub.name)
        let url = state.store.exportsDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
            showShare = true
        } catch {
            state.alertMessage = "写入失败：\(error.localizedDescription)"
        }
    }

    private func byteCount(_ text: String) -> String {
        let n = text.utf8.count
        if n < 1024 { return "\(n) B" }
        return String(format: "%.1f KB", Double(n) / 1024)
    }
}

// MARK: - 分享面板

/// `UIActivityViewController` 的 SwiftUI 包装。
public struct ShareSheet: UIViewControllerRepresentable {
    public let items: [Any]

    public init(items: [Any]) {
        self.items = items
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 二维码

public enum QRCode {

    /// 生成二维码 UIImage。内容超过编码容量时返回 nil。
    public static func image(from text: String) -> UIImage? {
        let data = Data(text.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // 中等纠错：容量与鲁棒性折中。
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale: CGFloat = 8
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
