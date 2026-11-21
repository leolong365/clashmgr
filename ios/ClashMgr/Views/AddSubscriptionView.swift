import SwiftUI
import UniformTypeIdentifiers

/// 新增订阅。
public struct AddSubscriptionView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable {
        case url = "订阅链接"
        case paste = "粘贴配置"
        case file = "文件导入"
    }

    @State private var mode: Mode = .url
    @State private var urlString = ""
    @State private var name = ""
    @State private var pasted = ""
    @State private var showImporter = false
    @State private var importError: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("来源", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("名称（可留空）") {
                    TextField("例如：主力机场", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                switch mode {
                case .url:
                    Section {
                        TextField("https://example.com/sub?token=...", text: $urlString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: {
                        Text("订阅地址")
                    } footer: {
                        Text("会以 User-Agent「\(settings.userAgent)」请求，多数机场据此返回 Clash 格式。")
                    }

                case .paste:
                    Section("配置内容") {
                        TextEditor(text: $pasted)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 220)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                case .file:
                    Section {
                        Button("选择 YAML 文件") { showImporter = true }
                    } footer: {
                        Text("从「文件」App 选择 .yaml / .yml / .txt 配置。")
                    }
                }

                if let e = importError {
                    Section {
                        Text(e)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { commit() }
                        .disabled(!canCommit || state.isBusy)
                }
            }
            .overlay {
                if state.isBusy {
                    ProgressView("正在下载…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: Self.allowedTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        if let yaml = UTType(filenameExtension: "yaml") { types.append(yaml) }
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        return types
    }

    private var canCommit: Bool {
        switch mode {
        case .url: return !urlString.trimmingCharacters(in: .whitespaces).isEmpty
        case .paste: return !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file: return !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func commit() {
        importError = nil
        switch mode {
        case .url:
            let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
            state.addFromURL(urlString, name: finalName)
            dismiss()
        case .paste, .file:
            state.addFromText(pasted, name: name)
            dismiss()
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                pasted = text
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    name = url.deletingPathExtension().lastPathComponent
                }
                importError = nil
            } catch {
                importError = "读取文件失败：\(error.localizedDescription)"
            }
        }
    }
}
