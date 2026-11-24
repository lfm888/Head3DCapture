import SwiftUI
import UIKit

/// 「存储诊断」页：用来确认数据到底写到了哪里、以及 iOS 是否把沙盒 Documents 暴露给了「文件」App。
/// iOS 18 有已知回归：即使 Info.plist 里 `UIFileSharingEnabled` / `LSSupportsOpeningInPlace` 都是 true，
/// 部分 App 的 Documents 也不会出现在「On My iPhone」里（数据其实在，见 设置 › 通用 › iPhone 储存空间）。
struct StorageDiagnosticsView: View {
    @ObservedObject var manager: TrueDepthCaptureManager
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private let flags = ["UIFileSharingEnabled", "LSSupportsOpeningInPlace", "UISupportsDocumentBrowser"]

    var body: some View {
        NavigationStack {
            List {
                Section("Info.plist（安装包里实际值）") {
                    ForEach(flags, id: \.self) { key in
                        infoRow(key)
                    }
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "-")
                    LabeledContent("显示名", value: AppPaths.appDisplayName)
                }

                Section("沙盒里的真实路径") {
                    if let path = manager.lastCaptureURL?.path {
                        Text(path)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("尚未保存过").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("最近一次写入的文件（回读校验）") {
                    if manager.lastStoredFiles.isEmpty {
                        Text("无").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.lastStoredFiles) { file in
                            HStack {
                                Text(file.name).font(.caption.monospaced())
                                Spacer()
                                Text(file.displaySize).font(.caption.monospaced())
                                    .foregroundStyle(file.bytes > 0 ? .secondary : .red)
                            }
                        }
                    }
                }

                Section("Documents 目录扫描") {
                    ForEach(scan(), id: \.0) { row in
                        HStack {
                            Text(row.0).font(.caption2.monospaced()).lineLimit(1)
                            Spacer()
                            Text(row.1).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("额外同步目录（绕开「文件」App 的沙盒展示问题）") {
                    Text(manager.outputFolderName.map { "当前: \($0)" } ?? "未设置")
                        .font(.footnote)
                    Button("选择同步目录…") { manager.chooseOutputFolder() }
                    if manager.outputFolderName != nil {
                        Button("取消同步目录", role: .destructive) { manager.clearOutputFolder() }
                    }
                    if let url = manager.lastCaptureURL {
                        Button("把最近一次采集导出到「文件」…") { FileExporter.export([url]) }
                    }
                }

                Section {
                    Button(copied ? "已复制到剪贴板" : "复制诊断信息") { copyAll() }
                }
            }
            .navigationTitle("存储诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - Helpers

    private func infoRow(_ key: String) -> some View {
        HStack {
            Text(key).font(.caption.monospaced())
            Spacer()
            Text(infoValue(key))
                .font(.caption.monospaced())
                .foregroundStyle(infoValue(key) == "true" ? .green : .red)
        }
    }

    private func infoValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) else { return "缺失" }
        if let number = value as? NSNumber { return number.boolValue ? "true" : "false" }
        return "\(value)"
    }

    private func scan() -> [(String, String)] {
        let fm = FileManager.default
        var rows: [(String, String)] = []
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return [("Documents", "不可用")]
        }
        let items = (try? fm.contentsOfDirectory(atPath: docs.path)) ?? []
        rows.append(("Documents", "\(items.count) 项"))
        for name in items.sorted().prefix(10) {
            let url = docs.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let sub = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                rows.append(("  \(name)/", "\(sub.count) 项"))
            } else {
                let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                rows.append(("  \(name)", StoredFile.format(size)))
            }
        }
        return rows
    }

    private func copyAll() {
        var lines: [String] = ["bundle: \(Bundle.main.bundleIdentifier ?? "-")"]
        for key in flags { lines.append("\(key) = \(infoValue(key))") }
        lines.append("filesApp: \(AppPaths.filesAppRoot)")
        lines.append("sandbox: \(manager.lastCaptureURL?.path ?? "-")")
        for file in manager.lastStoredFiles { lines.append("file: \(file.name) \(file.displaySize)") }
        for row in scan() { lines.append("scan: \(row.0) = \(row.1)") }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        copied = true
    }
}
