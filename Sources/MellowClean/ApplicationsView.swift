import SwiftUI
import AppKit
import MellowCore

@MainActor
final class ApplicationsModel: ObservableObject {
    @Published var scan = ApplicationScan()
    @Published var query = ""
    @Published var busy = false
    @Published var loaded = false
    @Published var pending: InstalledApplication?
    @Published var result: Message?

    var filtered: [InstalledApplication] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return scan.applications.filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) || $0.url.path.localizedCaseInsensitiveContains(text) }
    }
    func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            scan = await Task.detached { ApplicationUninstaller().scan() }.value
            loaded = true; busy = false
        }
    }
    func uninstall(_ app: InstalledApplication) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                _ = try await Task.detached { try ApplicationUninstaller().trash(app) }.value
                result = Message("已将 \(app.name) 移至废纸篓。应用数据已保留，可从废纸篓恢复应用。", "Moved \(app.name) to Trash. Application data is kept. You can restore the app from Trash.")
            } catch { result = Message(error: error).prefixed(app.name) }
            scan = await Task.detached { ApplicationUninstaller().scan() }.value
            busy = false
        }
    }
}

struct ApplicationsView: View {
    @StateObject private var model = ApplicationsModel()
    @EnvironmentObject private var preferences: Preferences
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField(preferences.text("搜索应用名称或路径", "Search by name or path"), text: $model.query)
                    .textFieldStyle(.roundedBorder)
                if model.busy { ProgressView().controlSize(.small) }
                Button(preferences.text("刷新", "Refresh")) { model.refresh() }.disabled(model.busy)
            }
            Text(preferences.text("应用程序与个人 Applications 文件夹 · \(model.scan.applications.count) 个应用", "Applications and your personal Applications folder · \(model.scan.applications.count) apps"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.loaded && model.filtered.isEmpty {
                        Text(preferences.text("没有找到匹配的应用", "No matching applications"))
                            .foregroundStyle(.secondary).padding(32)
                    }
                    ForEach(model.filtered) { app in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).fontWeight(.medium).lineLimit(1)
                                Text(app.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if let reason = app.blocked {
                                    Text(preferences.text(reason)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: { Image(systemName: "folder") }
                                .help(preferences.text("在 Finder 查看", "Show in Finder"))
                                .accessibilityLabel(preferences.text("在 Finder 查看 \(app.name)", "Show \(app.name) in Finder"))
                            Button(preferences.text("卸载…", "Uninstall…")) { model.pending = app }
                                .disabled(model.busy || app.blocked != nil)
                                .accessibilityLabel(preferences.text("卸载 \(app.name)", "Uninstall \(app.name)"))
                        }.padding(14).background(.white).cornerRadius(12)
                    }
                    ForEach(Array(model.scan.notes.enumerated()), id: \.offset) { _, note in
                        Text(preferences.text(note)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let result = model.result {
                Text(preferences.text(result)).font(.caption).textSelection(.enabled)
            }
            Text(preferences.text("仅移至废纸篓，保留文档与应用数据。含驱动或后台服务的软件请使用厂商卸载器。", "Moves only the app to Trash; documents and app data are kept. Use the vendor uninstaller for drivers or background services."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: active) { if $0 && !model.loaded { model.refresh() } }
        .alert(preferences.text("将应用移至废纸篓？", "Move application to Trash?"), isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }), presenting: model.pending) { app in
            Button(preferences.text("取消", "Cancel"), role: .cancel) { model.pending = nil }
            Button(preferences.text("移至废纸篓", "Move to Trash"), role: .destructive) { model.pending = nil; model.uninstall(app) }
        } message: { app in
            Text("\(app.name)\n\(app.url.path)\n\n" + preferences.text("应用本体将移至废纸篓，可恢复。偏好设置、账号数据和文档不会删除；清倒废纸篓后才会释放空间。", "The application will move to Trash and can be restored. Preferences, account data and documents are kept. Space is reclaimed after emptying Trash."))
        }
    }
}
