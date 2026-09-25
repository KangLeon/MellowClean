import Foundation
import AppKit

public struct InstalledApplication: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let blocked: Message?
    let fingerprint: String
}

public struct ApplicationScan: Sendable {
    public init() {}
    public var applications: [InstalledApplication] = []
    public var notes: [Message] = []
}

public struct ApplicationUninstaller {
    private let roots: [URL]
    private let fm = FileManager.default

    public init() {
        roots = [URL(fileURLWithPath: "/Applications"),
                 FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }
    // Internal roots let tests exercise the same checks with disposable bundles.
    init(roots: [URL]) { self.roots = roots }

    public func scan() -> ApplicationScan {
        var result = ApplicationScan()
        let running = Self.runningURLs()
        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            do {
                for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) where url.pathExtension.lowercased() == "app" {
                    do { result.applications.append(try inspect(url, running: running)) }
                    catch { result.notes.append(Message(error: error).prefixed(url.lastPathComponent)) }
                }
            } catch { result.notes.append(Message(error: error).prefixed(root.path)) }
        }
        result.applications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    func inspect(_ url: URL, running: [URL]) throws -> InstalledApplication {
        let path = url
        guard roots.contains(where: { $0.path == path.deletingLastPathComponent().path }), path.pathExtension.lowercased() == "app",
              physicalPath(path) == path.path,
              (try path.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw CleanError.unsafe(Message("路径不在应用目录内，或是符号链接，已保留。", "Outside the application folders or a symbolic link; kept."))
        }
        let info = path.appendingPathComponent("Contents/Info.plist")
        guard physicalPath(info) == info.path,
              let data = try? Data(contentsOf: info),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundlePackageType"] as? String == "APPL",
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw CleanError.unsafe(Message("无法确认应用身份，已保留。", "Cannot verify the application identity; kept."))
        }
        let attributes = try fm.attributesOfItem(atPath: path.path)
        let fingerprint = [FileAttributeKey.systemNumber, .systemFileNumber, .creationDate, .modificationDate]
            .map { String(describing: attributes[$0]) }.joined(separator: ":") + data.base64EncodedString()
        let blocked: Message?
        if identifier.lowercased().hasPrefix("com.apple.") || identifier == "io.github.kangleon.mellowclean" {
            blocked = Message("受保护的应用", "Protected application")
        } else if running.contains(where: { $0.path == path.path || $0.path.hasPrefix(path.path + "/") }) {
            blocked = Message("正在运行，请先退出后刷新", "Running; quit it and refresh first")
        } else if !fm.isDeletableFile(atPath: path.path) {
            blocked = Message("没有移除权限，请在 Finder 中处理", "No permission to remove; use Finder")
        } else { blocked = nil }
        return InstalledApplication(url: path, name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? path.deletingPathExtension().lastPathComponent,
                                    bundleID: identifier, blocked: blocked, fingerprint: fingerprint)
    }

    func validate(_ app: InstalledApplication, running: [URL]) throws {
        let current = try inspect(app.url, running: running)
        if let blocked = current.blocked { throw CleanError.unsafe(blocked) }
        guard current.fingerprint == app.fingerprint, current.bundleID == app.bundleID else {
            throw CleanError.unsafe(Message("应用自扫描后发生变化，请刷新后重试。", "Application changed since scanning. Refresh and try again."))
        }
    }

    @discardableResult
    public func trash(_ app: InstalledApplication) throws -> URL {
        try validate(app, running: Self.runningURLs())
        var destination: NSURL?
        try fm.trashItem(at: app.url, resultingItemURL: &destination)
        return destination as URL? ?? app.url
    }

    private static func runningURLs() -> [URL] {
        NSWorkspace.shared.runningApplications.flatMap { [$0.bundleURL, $0.executableURL].compactMap { url in
            guard let url, let path = physicalPath(url) else { return nil }
            return URL(fileURLWithPath: path)
        } }
    }
}
