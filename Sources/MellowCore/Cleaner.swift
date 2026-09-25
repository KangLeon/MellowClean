import Foundation
import CryptoKit
import Darwin

// Foundation removes /private from some resolved paths; realpath keeps one canonical spelling.
func physicalPath(_ url: URL) -> String? {
    guard let pointer = realpath(url.path, nil) else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
}

public struct Category: Identifiable, Sendable {
    public let id: String
    public let title: Message
    public let detail: Message
    public let relativePath: String
    public let processes: [String]

    public static let all: [Category] = [
        .init(id: "homebrew", title: .init("Homebrew 下载", "Homebrew downloads"), detail: .init("已下载的安装包；下次安装可能重新下载。", "Downloaded installers; future installs may download them again."), relativePath: "Library/Caches/Homebrew/downloads", processes: ["brew", "ruby", "curl"]),
        .init(id: "xcode", title: .init("Xcode 构建", "Xcode builds"), detail: .init("编译产物和索引；下次构建会慢一些。保留归档和模拟器。", "Build output and indexes; the next build may take longer. Archives and simulators stay."), relativePath: "Library/Developer/Xcode/DerivedData", processes: ["Xcode", "xcodebuild", "swift", "clang", "SourceKitService"]),
        .init(id: "go", title: .init("Go 编译", "Go build cache"), detail: .init("可重新生成的编译缓存，不删除源码或模块。", "Rebuildable compiler cache. Source code and modules stay."), relativePath: "Library/Caches/go-build", processes: ["go", "compile", "link"]),
        .init(id: "npm", title: .init("npm 下载", "npm downloads"), detail: .init("包下载缓存；保留 node_modules 和 npx 运行环境。", "Downloaded packages. Keeps node_modules and npx environments."), relativePath: ".npm/_cacache", processes: ["node", "npm", "npx"]),
        .init(id: "pip", title: .init("Python 下载", "Python downloads"), detail: .init("pip 下载缓存；保留虚拟环境和已安装的包。", "pip downloads. Keeps virtual environments and installed packages."), relativePath: "Library/Caches/pip", processes: ["pip", "pip3", "python", "python3"]),
        .init(id: "chrome", title: .init("Chrome 网页缓存", "Chrome web cache"), detail: .init("需先退出 Chrome；不碰历史、密码、书签或登录资料。", "Quit Chrome first. History, passwords, bookmarks and sign-in data stay."), relativePath: "Library/Caches/Google/Chrome", processes: ["Google Chrome", "Google Chrome Helper", "chrome_crashpad_handler"]),
        .init(id: "firefox", title: .init("Firefox 网页缓存", "Firefox web cache"), detail: .init("需先退出 Firefox；保留浏览器用户资料。", "Quit Firefox first. Browser profiles stay."), relativePath: "Library/Caches/Firefox", processes: ["firefox", "plugin-container"]),
        .init(id: "diagnostics", title: .init("旧崩溃报告", "Old crash reports"), detail: .init("旧诊断报告，清理后无法用于排查过去的崩溃。", "Old diagnostic reports. Deleted reports cannot be used to investigate past crashes."), relativePath: "Library/Logs/DiagnosticReports", processes: ["ReportCrash"])
    ]
}

public struct Candidate: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let categoryID: String
    public let path: String
    public let bytes: Int64
    public let fingerprint: String
}

public struct Scan: Codable, Sendable {
    public var candidates: [Candidate] = []
    public var notes: [Message] = []
    public var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
    public init() {}
}

public struct CleanResult: Sendable {
    public var bytes: Int64 = 0
    public var count = 0
    public var errors: [Message] = []
}

public enum CleanError: LocalizedError {
    case unsafe(Message)
    public var errorDescription: String? {
        switch self { case .unsafe(let message): return message.rendered() }
    }
}

public func formattedBytes(_ bytes: Int64) -> String {
    bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

public struct Cleaner: Sendable {
    public let home: URL
    public let days: Int
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, days: Int = 7) {
        self.home = URL(fileURLWithPath: physicalPath(home) ?? home.path)
        self.days = max(1, days)
    }

    public static func runningProcesses() throws -> Set<String> {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CleanError.unsafe(.init("无法检查正在运行的应用，本次不清理。", "Cannot check running applications. No cleanup will run."))
        }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)).lastPathComponent.lowercased()
        })
    }

    private func isBusy(_ category: Category, _ processes: Set<String>) -> Bool {
        category.processes.contains { hint in
            processes.contains { $0 == hint.lowercased() || $0.hasPrefix(hint.lowercased() + " (") }
        }
    }

    private func root(_ category: Category) -> URL { home.appendingPathComponent(category.relativePath) }

    // Refuse symlinks in any ancestor, including a redirected cache root.
    private func validate(_ url: URL) throws {
        let path = url.path
        guard path.hasPrefix(home.path + "/"),
              physicalPath(url) == path else {
            throw CleanError.unsafe(.init("跳过重定向或越界路径：\(url.lastPathComponent)", "Skipped redirected or out-of-scope path: \(url.lastPathComponent)"))
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CleanError.unsafe(.init("跳过符号链接", "Skipped symbolic link")) }
    }

    private func inspect(_ url: URL, category: Category) throws -> Candidate {
        try validate(url)
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                       .contentModificationDateKey, .fileAllocatedSizeKey, .fileSizeKey]
        var urls = [url]
        let deadline = Date().addingTimeInterval(15)
        var walkError: Error?
        if try url.resourceValues(forKeys: keys).isDirectory == true {
            guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in
                walkError = error
                return false
            }) else { throw CleanError.unsafe(.init("无法读取目录", "Cannot read directory")) }
            for case let child as URL in walk {
                let value = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard value.isSymbolicLink != true else { throw CleanError.unsafe(.init("包含符号链接，已跳过", "Contains a symbolic link; skipped")) }
                urls.append(child)
                // ponytail: bound one subtree; incremental scanning can replace this for huge caches.
                guard urls.count <= 200_000, Date() < deadline else {
                    throw CleanError.unsafe(.init("目录过大，已跳过；可在 Finder 检查", "Directory exceeds scan limits; skipped. Review it in Finder."))
                }
            }
            if let walkError { throw walkError }
        }
        var size: Int64 = 0
        var hash = SHA256()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for item in urls.sorted(by: { $0.path < $1.path }) {
            let v = try item.resourceValues(forKeys: keys)
            guard v.isSymbolicLink != true, v.isDirectory == true || v.isRegularFile == true else {
                throw CleanError.unsafe(.init("包含非普通文件，已跳过", "Contains special files; skipped"))
            }
            guard let modified = v.contentModificationDate, modified < cutoff else {
                throw CleanError.unsafe(.init("最近 \(days) 天有更新，已保留", "Updated within the last \(days) days; kept"))
            }
            let attributes = try fm.attributesOfItem(atPath: item.path)
            guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 || v.isDirectory == true else {
                throw CleanError.unsafe(.init("包含硬链接，已保留", "Contains a hard link; kept"))
            }
            if v.isRegularFile == true { size += Int64(v.fileAllocatedSize ?? v.fileSize ?? 0) }
            let record = "\(item.path)\u{0}\(attributes[.systemFileNumber] ?? "")\u{0}\(modified.timeIntervalSince1970)\u{0}\(v.fileSize ?? 0)\n"
            hash.update(data: Data(record.utf8))
        }
        return Candidate(categoryID: category.id, path: url.path, bytes: size,
                         fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public func scan(processes: Set<String>) -> Scan {
        var result = Scan()
        for category in Category.all {
            let folder = root(category)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            if isBusy(category, processes) {
                result.notes.append(.init("\(category.title.chinese)：相关应用正在运行，已跳过。", "\(category.title.english): a related application is running; skipped."))
                continue
            }
            do {
                try validate(folder)
                let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                var skipped = 0
                for child in children {
                    // Cache metadata belongs to the owning tool.
                    guard child.lastPathComponent != "CACHEDIR.TAG", !child.lastPathComponent.hasPrefix(".") else { continue }
                    do {
                        let candidate = try inspect(child, category: category)
                        if candidate.bytes > 0 { result.candidates.append(candidate) }
                    } catch { skipped += 1 }
                }
                if skipped > 0 { result.notes.append(.init("\(category.title.chinese)：保留 \(skipped) 项近期更新、链接或无法完整检查的内容。", "\(category.title.english): kept \(skipped) recent, linked or incompletely checked items.")) }
            } catch { let message = Message(error: error)
                result.notes.append(.init("\(category.title.chinese)：\(message.chinese)", "\(category.title.english): \(message.english)")) }
        }
        result.candidates.sort { $0.bytes > $1.bytes }
        return result
    }

    public func clean(_ candidates: [Candidate], permanently: Bool = false,
                      processes: Set<String>) -> CleanResult {
        var result = CleanResult()
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.path).inserted {
            do {
                guard let category = Category.all.first(where: { $0.id == candidate.categoryID }),
                      !isBusy(category, processes) else { throw CleanError.unsafe(.init("应用正在运行或分类无效", "Application is running or category is invalid")) }
                let url = URL(fileURLWithPath: candidate.path)
                guard url.deletingLastPathComponent().path == root(category).path,
                      !url.lastPathComponent.hasPrefix("."), url.lastPathComponent != "CACHEDIR.TAG" else {
                    throw CleanError.unsafe(.init("路径不在允许清理的范围内", "Path is outside the cleanup allowlist"))
                }
                let current = try inspect(url, category: category)
                guard current.fingerprint == candidate.fingerprint, current.bytes == candidate.bytes else {
                    throw CleanError.unsafe(.init("扫描后内容已变化，请重新扫描", "Contents changed after scanning. Please scan again."))
                }
                if permanently {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                result.bytes += current.bytes
                result.count += 1
            } catch { result.errors.append(Message(error: error).prefixed(URL(fileURLWithPath: candidate.path).lastPathComponent)) }
        }
        return result
    }
}

public struct LargeFile: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
}

public struct LargeFileScan: Sendable {
    public var files: [LargeFile] = []
    public var notes: [Message] = []
}

// Personal files are review-only: the cleaner cannot delete these paths.
public func findLargeFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> LargeFileScan {
    var result = LargeFileScan()
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    for name in ["Downloads", "Desktop", "Documents", "Movies"] {
        let folder = URL(fileURLWithPath: physicalPath(home) ?? home.path).appendingPathComponent(name)
        guard physicalPath(folder) == folder.path else { continue }
        guard FileManager.default.fileExists(atPath: folder.path) else { continue }
        var failed = false
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in failed = true; return true }) else { continue }
        let deadline = Date().addingTimeInterval(20)
        var visited = 0
        for case let url as URL in walk {
            visited += 1
            if Date() > deadline || visited > 200_000 {
                result.notes.append(.init("\(name)：达到扫描上限，结果不完整。", "\(name): scan limit reached; results are incomplete."))
                break
            }
            if ["node_modules", "Pods", "venv", "build"].contains(url.lastPathComponent) {
                walk.skipDescendants(); continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true,
                  v.isRegularFile == true, let size = v.fileSize, size >= 100_000_000 else { continue }
            result.files.append(.init(url: url, bytes: Int64(size)))
        }
        if failed { result.notes.append(.init("\(name)：部分目录无权限读取。", "\(name): permission denied for some directories.")) }
    }
    result.files = Array(result.files.sorted { $0.bytes > $1.bytes }.prefix(100))
    return result
}
