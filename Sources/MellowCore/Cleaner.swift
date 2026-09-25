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
    public let title: String
    public let detail: String
    public let relativePath: String
    public let processes: [String]

    public static let all: [Category] = [
        .init(id: "homebrew", title: "Homebrew 下载", detail: "已下载的安装包；下次安装可能重新下载。", relativePath: "Library/Caches/Homebrew/downloads", processes: ["brew", "ruby", "curl"]),
        .init(id: "xcode", title: "Xcode 构建", detail: "编译产物和索引；下次构建会慢一些。保留归档和模拟器。", relativePath: "Library/Developer/Xcode/DerivedData", processes: ["Xcode", "xcodebuild", "swift", "clang", "SourceKitService"]),
        .init(id: "go", title: "Go 编译", detail: "可重新生成的编译缓存，不删除源码或模块。", relativePath: "Library/Caches/go-build", processes: ["go", "compile", "link"]),
        .init(id: "npm", title: "npm 下载", detail: "包下载缓存；保留 node_modules 和 npx 运行环境。", relativePath: ".npm/_cacache", processes: ["node", "npm", "npx"]),
        .init(id: "pip", title: "Python 下载", detail: "pip 下载缓存；保留虚拟环境和已安装的包。", relativePath: "Library/Caches/pip", processes: ["pip", "pip3", "python", "python3"]),
        .init(id: "chrome", title: "Chrome 网页缓存", detail: "需先退出 Chrome；不碰历史、密码、书签或登录资料。", relativePath: "Library/Caches/Google/Chrome", processes: ["Google Chrome", "Google Chrome Helper", "chrome_crashpad_handler"]),
        .init(id: "firefox", title: "Firefox 网页缓存", detail: "需先退出 Firefox；保留浏览器用户资料。", relativePath: "Library/Caches/Firefox", processes: ["firefox", "plugin-container"]),
        .init(id: "diagnostics", title: "旧崩溃报告", detail: "旧诊断报告，清理后无法用于排查过去的崩溃。", relativePath: "Library/Logs/DiagnosticReports", processes: ["ReportCrash"])
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
    public var notes: [String] = []
    public var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
    public init() {}
}

public struct CleanResult: Sendable {
    public var bytes: Int64 = 0
    public var count = 0
    public var errors: [String] = []
}

public enum CleanError: LocalizedError {
    case unsafe(String)
    public var errorDescription: String? {
        switch self { case .unsafe(let message): return message }
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
            throw CleanError.unsafe("无法检查正在运行的应用，本次不清理。")
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
            throw CleanError.unsafe("跳过重定向或越界路径：\(url.lastPathComponent)")
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CleanError.unsafe("跳过符号链接") }
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
            }) else { throw CleanError.unsafe("无法读取目录") }
            for case let child as URL in walk {
                let value = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard value.isSymbolicLink != true else { throw CleanError.unsafe("包含符号链接，已跳过") }
                urls.append(child)
                // ponytail: bound one subtree; incremental scanning can replace this for huge caches.
                guard urls.count <= 200_000, Date() < deadline else {
                    throw CleanError.unsafe("目录过大，已跳过；可在 Finder 检查")
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
                throw CleanError.unsafe("包含非普通文件，已跳过")
            }
            guard let modified = v.contentModificationDate, modified < cutoff else {
                throw CleanError.unsafe("最近 \(days) 天有更新，已保留")
            }
            let attributes = try fm.attributesOfItem(atPath: item.path)
            guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 || v.isDirectory == true else {
                throw CleanError.unsafe("包含硬链接，已保留")
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
                result.notes.append("\(category.title)：相关应用正在运行，已跳过。")
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
                if skipped > 0 { result.notes.append("\(category.title)：保留 \(skipped) 项近期更新、链接或无法完整检查的内容。") }
            } catch { result.notes.append("\(category.title)：\(error.localizedDescription)") }
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
                      !isBusy(category, processes) else { throw CleanError.unsafe("应用正在运行或分类无效") }
                let url = URL(fileURLWithPath: candidate.path)
                guard url.deletingLastPathComponent().path == root(category).path,
                      !url.lastPathComponent.hasPrefix("."), url.lastPathComponent != "CACHEDIR.TAG" else {
                    throw CleanError.unsafe("路径不在允许清理的范围内")
                }
                let current = try inspect(url, category: category)
                guard current.fingerprint == candidate.fingerprint, current.bytes == candidate.bytes else {
                    throw CleanError.unsafe("扫描后内容已变化，请重新扫描")
                }
                if permanently {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                result.bytes += current.bytes
                result.count += 1
            } catch { result.errors.append("\(URL(fileURLWithPath: candidate.path).lastPathComponent)：\(error.localizedDescription)") }
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
    public var notes: [String] = []
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
                result.notes.append("\(name)：达到扫描上限，结果不完整。")
                break
            }
            if ["node_modules", "Pods", "venv", "build"].contains(url.lastPathComponent) {
                walk.skipDescendants(); continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true,
                  v.isRegularFile == true, let size = v.fileSize, size >= 100_000_000 else { continue }
            result.files.append(.init(url: url, bytes: Int64(size)))
        }
        if failed { result.notes.append("\(name)：部分目录无权限读取。") }
    }
    result.files = Array(result.files.sorted { $0.bytes > $1.bytes }.prefix(100))
    return result
}
