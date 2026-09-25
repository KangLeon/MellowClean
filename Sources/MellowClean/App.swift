import SwiftUI
import AppKit
import MellowCore

@main
struct MellowCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var preferences = Preferences()
    var body: some Scene {
        WindowGroup { Dashboard().environmentObject(preferences).frame(minWidth: 980, minHeight: 720) }
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appSettings) {
                    SettingsButton().environmentObject(preferences).keyboardShortcut(",", modifiers: .command)
                }
            }
        Settings { SettingsView().environmentObject(preferences) }
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
    @Published var status = Message("从一次扫描开始。所有决定都由你来做。", "Start with a scan. Every choice stays yours.")
    @Published var free: Int64 = 0
    @Published var total: Int64 = 1
    @Published var days = 7
    @Published var permanent = false
    @Published var largeNotes: [Message] = []
    @Published var report: [Message]?
    @Published var page = "caches"
    @Published var confirm = false
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
        busy = true; status = Message("正在检查缓存与应用状态…", "Checking caches and running applications…")
        let age = days
        Task {
            do {
                let found = try await Task.detached {
                    Cleaner(days: age).scan(processes: try Cleaner.runningProcesses())
                }.value
                scan = found; selected = []; scanned = true; scanDays = age
                status = found.candidates.isEmpty ? Message("检查完成。暂时没有符合条件的旧缓存。", "Scan complete. No eligible old caches found.") : Message("扫描完成。选择要处理的分类，可先在 Finder 查看。", "Scan complete. Choose categories, or review them in Finder first.")
            } catch { status = Message(error: error) }
            disk(); busy = false
        }
    }
    func scanLarge() {
        guard !busy else { return }
        busy = true; status = Message("正在查找个人文件夹中大于 100 MB 的文件…", "Finding files larger than 100 MB in your personal folders…")
        Task {
            let result = await Task.detached { findLargeFiles() }.value
            large = result.files; largeNotes = result.notes
            status = Message("找到 \(large.count) 个大文件。仅供查看，由你判断是否需要保留。", "Found \(large.count) large files. Review them and decide what to keep.")
            busy = false
        }
    }
    func clean() {
        guard !busy, !chosen.isEmpty else { return }
        let items = chosen, mode = permanent, age = scanDays
        busy = true; status = Message("正在重新检查并处理所选缓存…", "Rechecking and processing selected caches…")
        Task {
            do {
                let result = try await Task.detached {
                    Cleaner(days: age).clean(items, permanently: mode, processes: try Cleaner.runningProcesses())
                }.value
                let summary = Message(
                    "已\(mode ? "永久删除" : "移至废纸篓") \(result.count) 项，估算 \(formattedBytes(result.bytes))。",
                    "\(mode ? "Permanently deleted" : "Moved to Trash"): \(result.count) items, approximately \(formattedBytes(result.bytes)).")
                status = summary
                report = [summary, mode
                    ? Message("实际可用空间可能受 APFS 快照影响。", "APFS snapshots may affect the space reclaimed.")
                    : Message("如需释放空间，请在 Finder 检查并清倒废纸篓；也可从废纸篓拖回原位置。", "Review and empty Trash in Finder to reclaim space. To restore an item, drag it back to its original location.")]
                if !result.errors.isEmpty {
                    report?.append(Message("未处理的项目：", "Skipped items:"))
                    report?.append(contentsOf: result.errors)
                }
                scan = Scan(); selected = []; scanned = false
            } catch { status = Message(error: error) }
            disk(); busy = false
        }
    }
}

struct Dashboard: View {
    @StateObject private var model = Model()
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigation
    private let green = Color(red: 0.17, green: 0.39, blue: 0.30)
    private let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.24) }
    private var entrance: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 38, height: 38).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MellowClean").font(.headline)
                        Text(preferences.text("给 Mac 留点余地", "Room to breathe.")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 24)
                VStack(spacing: 8) {
                    nav("caches", preferences.text("缓存清理", "Cache cleanup"), "sparkles")
                    nav("large", preferences.text("大文件", "Large files"), "doc.text.magnifyingglass")
                }.animation(motion, value: model.page)
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label(preferences.text("本地处理 · 无追踪", "Local. No tracking."), systemImage: "lock.shield")
                    Text(preferences.text("不需要管理员权限\n不自动删除个人文件", "No administrator access.\nYour personal files stay yours."))
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
                }.font(.caption).padding(14).background(.white.opacity(0.65)).cornerRadius(12)
                SettingsButton().buttonStyle(.plain)
                Text(preferences.text("开源 · v0.2.1", "Open source · v0.2.1")).font(.caption2).foregroundStyle(.secondary)
            }.padding(24).frame(width: 225).background(Color(red: 0.91, green: 0.93, blue: 0.88))
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.page == "caches" ? preferences.text("少一点杂物，多一点空间。", "Less clutter. More room.") : preferences.text("空间都去哪儿了？", "Where did the space go?"))
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text(model.page == "caches" ? preferences.text("只清理你看得懂、选得中的内容。", "Understand what goes. Choose what stays.") : preferences.text("先看清楚，再决定。个人文件不会自动删除。", "Review first. Personal files are never deleted automatically."))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }.padding(.top, 20)
                diskCard
                Group {
                    if model.page == "caches" { cacheContent } else { largeContent }
                }
                .id(model.page)
                .transition(entrance)
                .animation(motion, value: model.scanned)
                .animation(motion, value: model.scan.candidates.map(\.id))
                .animation(motion, value: model.large.map(\.id))
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    Text(preferences.text(model.status)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .id(model.status.chinese).transition(reduceMotion ? .identity : .opacity)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .animation(motion, value: model.status.chinese)
                if model.page == "caches" { footer.transition(entrance) }
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(paper)
                .animation(motion, value: model.page)
        }
        .environment(\.locale, Locale(identifier: preferences.language.resolved().rawValue))
        .preferredColorScheme(.light)
        .tint(green)
        .alert(model.permanent ? preferences.text("永久删除所选缓存？", "Permanently delete selected caches?") : preferences.text("将所选缓存移至废纸篓？", "Move selected caches to Trash?"), isPresented: $model.confirm) {
            Button(preferences.text("取消", "Cancel"), role: .cancel) {}
            Button(model.permanent ? preferences.text("永久删除", "Delete permanently") : preferences.text("移至废纸篓", "Move to Trash"), role: .destructive) { model.clean() }
        } message: {
            Text(preferences.text("\(model.selected.count) 个分类，约 \(formattedBytes(model.chosenBytes))。\n", "\(model.selected.count) categories, approximately \(formattedBytes(model.chosenBytes)).\n") +
                 (model.permanent ? preferences.text("此操作无法撤销。下次使用时可能需要重新下载或编译。", "This cannot be undone. Future use may require downloading or rebuilding files.") : preferences.text("可以从废纸篓找回。清倒废纸篓后才会释放磁盘空间。", "Files can be restored from Trash. Space is reclaimed only after emptying Trash.")))
        }
        .sheet(isPresented: Binding(get: { model.report != nil }, set: { if !$0 { model.report = nil } })) {
            VStack(alignment: .leading, spacing: 20) {
                Label(preferences.text("处理结果", "Cleanup results"), systemImage: "checkmark.circle").font(.title2)
                ScrollView { Text((model.report ?? []).map { preferences.text($0) }.joined(separator: "\n\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button(preferences.text("打开废纸篓", "Open Trash")) { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")) }
                    Spacer()
                    Button(preferences.text("完成", "Done")) { model.report = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 510, height: 300)
        }
    }

    private func nav(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { model.page = id } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background {
                    if model.page == id {
                        if reduceMotion {
                            RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.85))
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.85))
                                .matchedGeometryEffect(id: "navigation", in: navigation)
                        }
                    }
                }
        }.buttonStyle(MellowButtonStyle())
    }

    private var diskCard: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle().stroke(green.opacity(0.12), lineWidth: 9)
                Circle().trim(from: 0, to: CGFloat(max(0, min(1, Double(model.total - model.free) / Double(max(model.total, 1))))))
                    .stroke(green, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(motion, value: model.free)
                Circle().trim(from: 0, to: 0.2)
                    .stroke(green.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(-9)
                    .rotationEffect(.degrees(model.busy && !reduceMotion ? 360 : 0))
                    .animation(model.busy && !reduceMotion ? .linear(duration: 1.3).repeatForever(autoreverses: false) : nil, value: model.busy && !reduceMotion)
                    .opacity(model.busy ? 1 : 0).accessibilityHidden(true)
                Image(systemName: "internaldrive").font(.title2).foregroundStyle(green)
            }.frame(width: 70, height: 70).accessibilityLabel(preferences.text("磁盘剩余 \(formattedBytes(model.free))", "Disk space available: \(formattedBytes(model.free))"))
            VStack(alignment: .leading, spacing: 5) {
                Text(preferences.text("\(formattedBytes(model.free)) 可用", "\(formattedBytes(model.free)) available")).font(.system(size: 25, weight: .medium, design: .rounded))
                Text(preferences.text("磁盘总容量 \(formattedBytes(model.total))", "Disk capacity: \(formattedBytes(model.total))")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(formattedBytes(model.scan.bytes)).font(.title2).fontWeight(.semibold).foregroundStyle(green)
                Text(preferences.text("符合条件的缓存 · 估算", "Eligible caches · estimated")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).background(.white).cornerRadius(18)
    }

    private var cacheContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(preferences.text("可清理项目", "Cleanup candidates")).font(.headline)
                Spacer()
                Picker(preferences.text("保留近期内容", "Keep recent files"), selection: $model.days) {
                    Text(preferences.text("保留 1 天", "Keep 1 day")).tag(1)
                    Text(preferences.text("保留 7 天", "Keep 7 days")).tag(7)
                    Text(preferences.text("保留 30 天", "Keep 30 days")).tag(30)
                }.labelsHidden().frame(width: 140).disabled(model.busy)
                Button(model.scanned ? preferences.text("重新扫描", "Scan again") : preferences.text("开始扫描", "Start scan")) { model.refresh() }
                    .buttonStyle(MellowButtonStyle(prominent: true)).disabled(model.busy)
            }
            ScrollView {
                VStack(spacing: 10) {
                    if !model.scanned || model.scan.candidates.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 36)).foregroundStyle(green)
                            Text(model.scanned ? preferences.text("没有需要处理的旧缓存", "No old caches to clean") : preferences.text("先扫描，不会改动任何文件", "Scan first. Nothing is changed.")).font(.headline)
                            Text(model.scanned ? preferences.text("近期内容与正在使用的缓存已保留。\n想继续腾空间？试试左侧的大文件检查。", "Recent and active caches are kept.\nNeed more room? Try Large files in the sidebar.") : preferences.text("检查开发工具、浏览器缓存和旧诊断报告。\n近期更新或正在使用的内容会保留。", "Review developer caches, browser caches and old crash reports.\nRecent and active content is kept."))
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 42).transition(entrance)
                    }
                    ForEach(Category.all) { category in
                        let items = model.scan.candidates.filter { $0.categoryID == category.id }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle(isOn: Binding(get: { model.selected.contains(category.id) }, set: {
                                        if $0 { model.selected.insert(category.id) } else { model.selected.remove(category.id) }
                                    })) { Text(preferences.text(category.title)).fontWeight(.medium) }.toggleStyle(.checkbox).disabled(model.busy)
                                    Spacer()
                                    Text(formattedBytes(items.reduce(0) { $0 + $1.bytes })).fontWeight(.semibold).monospacedDigit()
                                    Button { reveal(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(category.relativePath)) }
                                        label: { Image(systemName: "folder") }.help(preferences.text("在 Finder 查看 \(preferences.text(category.title))", "Show \(preferences.text(category.title)) in Finder"))
                                }
                                Text(preferences.text(category.detail)).font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup(preferences.text("查看 \(items.count) 个项目", "Review \(items.count) items")) {
                                    ForEach(items) { item in
                                        HStack {
                                            Text(URL(fileURLWithPath: item.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Text(formattedBytes(item.bytes))
                                            Button(preferences.text("查看", "Show")) { reveal(URL(fileURLWithPath: item.path)) }
                                        }.font(.caption).help(item.path)
                                    }
                                }.font(.caption)
                            }.padding(16)
                                .background(model.selected.contains(category.id) ? green.opacity(0.08) : .white)
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(green.opacity(model.selected.contains(category.id) ? 0.35 : 0), lineWidth: 1))
                                .animation(motion, value: model.selected.contains(category.id))
                                .transition(entrance)
                        }
                    }
                    if !model.scan.notes.isEmpty {
                        DisclosureGroup(preferences.text("已保留或跳过的内容（\(model.scan.notes.count)）", "Kept or skipped (\(model.scan.notes.count))")) {
                            ForEach(Array(model.scan.notes.enumerated()), id: \.offset) { _, note in Text(preferences.text(note)).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3) }
                        }.font(.caption).padding(12)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(preferences.text("永久删除，立即释放空间", "Delete permanently to reclaim space"), isOn: $model.permanent).font(.caption).disabled(model.busy)
                Text(model.permanent ? preferences.text("不可撤销；实际释放量受快照影响。", "Cannot be undone. Snapshots may affect space reclaimed.") : preferences.text("默认移至废纸篓，清倒后释放空间。", "Trash is the default. Empty it to reclaim space."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button((model.permanent ? preferences.text("清理", "Clean") : preferences.text("移至废纸篓", "Move to Trash")) + " · " + formattedBytes(model.chosenBytes)) { model.confirm = true }
                .buttonStyle(MellowButtonStyle(prominent: true)).controlSize(.large).disabled(model.chosen.isEmpty || model.busy)
        }
    }

    private var largeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(preferences.text("个人文件夹 · 大于 100 MB · 最多 100 项", "Personal folders · Over 100 MB · Up to 100 files")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(preferences.text("查找大文件", "Find large files")) { model.scanLarge() }.buttonStyle(MellowButtonStyle(prominent: true)).disabled(model.busy)
            }
            ScrollView {
                VStack(spacing: 10) {
                    if model.large.isEmpty {
                        Text(preferences.text("检查下载、桌面、文稿和影片。\n点击“在 Finder 查看”后，可自行决定如何处理。", "Check Downloads, Desktop, Documents and Movies.\nReveal a file in Finder to decide what to do with it."))
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
                            Button(preferences.text("在 Finder 查看", "Show in Finder")) { reveal(file.url) }
                        }.padding(14).background(.white).cornerRadius(12).transition(entrance)
                    }
                    ForEach(Array(model.largeNotes.enumerated()), id: \.offset) { _, note in Text(preferences.text(note)).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

// One native button style keeps press feedback consistent without timers or gesture handlers.
private struct MellowButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, prominent ? 14 : 0)
            .padding(.vertical, prominent ? 9 : 0)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color(red: 0.17, green: 0.39, blue: 0.30) : .clear)
            .cornerRadius(9)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
