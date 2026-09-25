import SwiftUI
import AppKit
import MellowCore

@main
struct MellowCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { Dashboard().frame(minWidth: 900, minHeight: 680) }
            .windowStyle(.hiddenTitleBar)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class Model: ObservableObject {
    @Published var scan = Scan()
    @Published var large: [LargeFile] = []
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var scanned = false
    @Published var status = "从一次扫描开始。所有决定都由你来做。"
    @Published var free: Int64 = 0
    @Published var total: Int64 = 1
    @Published var days = 7
    @Published var permanent = false
    @Published var largeNotes: [String] = []
    @Published var report: String?
    private var scanDays = 7

    var chosen: [Candidate] { scan.candidates.filter { selected.contains($0.categoryID) } }
    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }

    init() { disk() }
    func disk() {
        if let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            free = (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            total = (values[.systemSize] as? NSNumber)?.int64Value ?? 1
        }
    }
    func refresh() {
        guard !busy else { return }
        busy = true; status = "正在检查缓存与应用状态…"
        let age = days
        Task {
            do {
                let found = try await Task.detached {
                    Cleaner(days: age).scan(processes: try Cleaner.runningProcesses())
                }.value
                scan = found; selected = []; scanned = true; scanDays = age
                status = found.candidates.isEmpty ? "检查完成。暂时没有符合条件的旧缓存。" : "扫描完成。选择要处理的分类，可先在 Finder 查看。"
            } catch { status = error.localizedDescription }
            disk(); busy = false
        }
    }
    func scanLarge() {
        guard !busy else { return }
        busy = true; status = "正在查找个人文件夹中大于 100 MB 的文件…"
        Task {
            let result = await Task.detached { findLargeFiles() }.value
            large = result.files; largeNotes = result.notes
            status = "找到 \(large.count) 个大文件。仅供查看，由你判断是否需要保留。"
            busy = false
        }
    }
    func clean() {
        guard !busy, !chosen.isEmpty else { return }
        let items = chosen, mode = permanent, age = scanDays
        busy = true; status = "正在重新检查并处理所选缓存…"
        Task {
            do {
                let result = try await Task.detached {
                    Cleaner(days: age).clean(items, permanently: mode, processes: try Cleaner.runningProcesses())
                }.value
                let summary = "已\(mode ? "永久删除" : "移至废纸篓") \(result.count) 项，估算 \(formattedBytes(result.bytes))。"
                status = summary
                report = summary + (mode ? "\n实际可用空间可能受 APFS 快照影响。" : "\n如需释放空间，请在 Finder 检查并清倒废纸篓；也可从废纸篓拖回原位置。")
                    + (result.errors.isEmpty ? "" : "\n\n未处理的项目：\n" + result.errors.joined(separator: "\n"))
                scan = Scan(); selected = []; scanned = false
            } catch { status = error.localizedDescription }
            disk(); busy = false
        }
    }
}

struct Dashboard: View {
    @StateObject private var model = Model()
    @State private var page = "caches"
    @State private var confirm = false
    private let green = Color(red: 0.17, green: 0.39, blue: 0.30)
    private let paper = Color(red: 0.97, green: 0.96, blue: 0.93)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill").font(.system(size: 26)).foregroundStyle(green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MellowClean").font(.headline)
                        Text("给 Mac 留点余地").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 24)
                VStack(spacing: 8) {
                    nav("caches", "缓存清理", "sparkles")
                    nav("large", "大文件", "doc.text.magnifyingglass")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label("本地处理 · 无追踪", systemImage: "lock.shield")
                    Text("不需要管理员权限\n不自动删除个人文件")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
                }.font(.caption).padding(14).background(.white.opacity(0.65)).cornerRadius(12)
                Text("开源 · v0.1.0").font(.caption2).foregroundStyle(.secondary)
            }.padding(24).frame(width: 210).background(Color(red: 0.91, green: 0.93, blue: 0.88))
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page == "caches" ? "少一点杂物，多一点空间。" : "空间都去哪儿了？")
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text(page == "caches" ? "只清理你看得懂、选得中的内容。" : "先看清楚，再决定。个人文件不会自动删除。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }.padding(.top, 20)
                diskCard
                if page == "caches" { cacheContent } else { largeContent }
                Spacer(minLength: 0)
                Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if page == "caches" { footer }
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(paper)
        }
        .preferredColorScheme(.light)
        .tint(green)
        .alert(model.permanent ? "永久删除所选缓存？" : "将所选缓存移至废纸篓？", isPresented: $confirm) {
            Button("取消", role: .cancel) {}
            Button(model.permanent ? "永久删除" : "移至废纸篓", role: .destructive) { model.clean() }
        } message: {
            Text("\(model.selected.count) 个分类，约 \(formattedBytes(model.chosenBytes))。\n" +
                 (model.permanent ? "此操作无法撤销。下次使用时可能需要重新下载或编译。" : "可以从废纸篓找回。清倒废纸篓后才会释放磁盘空间。"))
        }
        .sheet(isPresented: Binding(get: { model.report != nil }, set: { if !$0 { model.report = nil } })) {
            VStack(alignment: .leading, spacing: 20) {
                Label("处理结果", systemImage: "checkmark.circle").font(.title2)
                ScrollView { Text(model.report ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("打开废纸篓") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")) }
                    Spacer()
                    Button("完成") { model.report = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 510, height: 300)
        }
    }

    private func nav(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { page = id } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(page == id ? Color.white.opacity(0.85) : .clear).cornerRadius(10)
        }.buttonStyle(.plain)
    }

    private var diskCard: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle().stroke(green.opacity(0.12), lineWidth: 9)
                Circle().trim(from: 0, to: CGFloat(max(0, min(1, Double(model.total - model.free) / Double(max(model.total, 1))))))
                    .stroke(green, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "internaldrive").font(.title2).foregroundStyle(green)
            }.frame(width: 70, height: 70).accessibilityLabel("磁盘剩余 \(formattedBytes(model.free))")
            VStack(alignment: .leading, spacing: 5) {
                Text("\(formattedBytes(model.free)) 可用").font(.system(size: 25, weight: .medium, design: .rounded))
                Text("磁盘总容量 \(formattedBytes(model.total))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(formattedBytes(model.scan.bytes)).font(.title2).fontWeight(.semibold).foregroundStyle(green)
                Text("符合条件的缓存 · 估算").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).background(.white).cornerRadius(18)
    }

    private var cacheContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("可清理项目").font(.headline)
                Spacer()
                Picker("保留近期内容", selection: $model.days) {
                    Text("保留 1 天").tag(1)
                    Text("保留 7 天").tag(7)
                    Text("保留 30 天").tag(30)
                }.frame(width: 185).disabled(model.busy)
                Button(model.scanned ? "重新扫描" : "开始扫描") { model.refresh() }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
            }
            ScrollView {
                VStack(spacing: 10) {
                    if !model.scanned || model.scan.candidates.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 36)).foregroundStyle(green)
                            Text(model.scanned ? "没有需要处理的旧缓存" : "先扫描，不会改动任何文件").font(.headline)
                            Text(model.scanned ? "近期内容与正在使用的缓存已保留。\n想继续腾空间？试试左侧的大文件检查。" : "检查开发工具、浏览器缓存和旧诊断报告。\n近期更新或正在使用的内容会保留。")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 42)
                    }
                    ForEach(Category.all) { category in
                        let items = model.scan.candidates.filter { $0.categoryID == category.id }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle(isOn: Binding(get: { model.selected.contains(category.id) }, set: {
                                        if $0 { model.selected.insert(category.id) } else { model.selected.remove(category.id) }
                                    })) { Text(category.title).fontWeight(.medium) }.toggleStyle(.checkbox).disabled(model.busy)
                                    Spacer()
                                    Text(formattedBytes(items.reduce(0) { $0 + $1.bytes })).fontWeight(.semibold).monospacedDigit()
                                    Button { reveal(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(category.relativePath)) }
                                        label: { Image(systemName: "folder") }.help("在 Finder 查看 \(category.title)")
                                }
                                Text(category.detail).font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("查看 \(items.count) 个项目") {
                                    ForEach(items) { item in
                                        HStack {
                                            Text(URL(fileURLWithPath: item.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Text(formattedBytes(item.bytes))
                                            Button("查看") { reveal(URL(fileURLWithPath: item.path)) }
                                        }.font(.caption).help(item.path)
                                    }
                                }.font(.caption)
                            }.padding(16).background(.white).cornerRadius(12)
                        }
                    }
                    if !model.scan.notes.isEmpty {
                        DisclosureGroup("已保留或跳过的内容（\(model.scan.notes.count)）") {
                            ForEach(model.scan.notes, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3) }
                        }.font(.caption).padding(12)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("永久删除，立即释放空间", isOn: $model.permanent).font(.caption).disabled(model.busy)
                Text(model.permanent ? "不可撤销；实际释放量受快照影响。" : "默认移至废纸篓，清倒后释放空间。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("\(model.permanent ? "清理" : "移至废纸篓") · \(formattedBytes(model.chosenBytes))") { confirm = true }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.chosen.isEmpty || model.busy)
        }
    }

    private var largeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("个人文件夹 · 大于 100 MB · 最多 100 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("查找大文件") { model.scanLarge() }.buttonStyle(.borderedProminent).disabled(model.busy)
            }
            ScrollView {
                VStack(spacing: 10) {
                    if model.large.isEmpty {
                        Text("检查下载、桌面、文稿和影片。\n点击“在 Finder 查看”后，可自行决定如何处理。")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(40)
                    }
                    ForEach(model.large) { file in
                        HStack {
                            Image(systemName: "doc").foregroundStyle(green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(formattedBytes(file.bytes)).font(.caption)
                            Button("在 Finder 查看") { reveal(file.url) }
                        }.padding(14).background(.white).cornerRadius(12)
                    }
                    ForEach(model.largeNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
