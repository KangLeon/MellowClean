import Foundation
import MellowCore

let usage = """
MellowClean 0.2.0 — a calmer Mac, one informed choice at a time.

  mellowclean                  Open the native app
  mellowclean scan [--json]     Inspect known caches (read-only)
  mellowclean clean ID...       Preview, then move selected caches to Trash
      [--permanent]            Delete permanently after confirmation
      [--yes]                  Explicitly skip the interactive confirmation
  mellowclean --version

IDs: \(Category.all.map(\.id).joined(separator: ", "))
Recent files (7 days), busy apps, links and personal files are protected.
Trash does not free disk space until emptied in Finder.
"""

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = binary.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MellowClean.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw CleanError.unsafe("App bundle not found. Run scripts/build.sh and open dist/MellowClean.app, or use mellowclean scan.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [app.path]
        try p.run(); p.waitUntilExit()
        exit(p.terminationStatus)
    }
    if args == ["--version"] { print("0.2.0"); exit(0) }
    if args == ["--help"] || args == ["help"] { print(usage); exit(0) }
    let cleaner = Cleaner()
    let command = args[0]
    guard command == "scan" || command == "clean" else { throw CleanError.unsafe(.init(verbatim: usage)) }
    let allowedFlags: Set<String> = command == "scan" ? ["--json"] : ["--yes", "--permanent"]
    let flags = args.dropFirst().filter { $0.hasPrefix("-") }
    guard flags.allSatisfy({ allowedFlags.contains($0) }) else { throw CleanError.unsafe(.init(verbatim: "Unknown option.\n" + usage)) }
    let ids = Set(args.dropFirst().filter { !$0.hasPrefix("-") })
    guard command != "scan" || ids.isEmpty else { throw CleanError.unsafe(.init(verbatim: usage)) }
    guard ids.isSubset(of: Set(Category.all.map(\.id))), command != "clean" || !ids.isEmpty else {
        throw CleanError.unsafe(.init(verbatim: "Choose one or more valid cache IDs.\n" + usage))
    }
    let scan = cleaner.scan(processes: try Cleaner.runningProcesses())
    if flags.contains("--json") {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Output: Encodable { let candidates: [Candidate]; let notes: [String] }
        let output = Output(candidates: scan.candidates, notes: scan.notes.map { $0.rendered() })
        print(String(decoding: try encoder.encode(output), as: UTF8.self)); exit(0)
    }
    let chosen = scan.candidates.filter { command == "scan" || ids.contains($0.categoryID) }
    for category in Category.all {
        let items = chosen.filter { $0.categoryID == category.id }
        if !items.isEmpty {
            print("\(category.id): \(formattedBytes(items.reduce(0) { $0 + $1.bytes })) — \(category.title.rendered())")
            print("  \(category.detail.rendered())")
            for item in items { print("  \(formattedBytes(item.bytes))  \(item.path)") }
        }
    }
    scan.notes.forEach { print("• " + $0.rendered()) }
    print("Eligible: \(formattedBytes(chosen.reduce(0) { $0 + $1.bytes })) (estimate)")
    guard command == "clean", !chosen.isEmpty else { exit(0) }
    let permanent = flags.contains("--permanent")
    print(permanent ? "PERMANENT deletion. This cannot be undone." : "Move to Trash. Empty Trash in Finder to reclaim space.")
    if !flags.contains("--yes") {
        guard isatty(STDIN_FILENO) != 0 else { throw CleanError.unsafe("Non-interactive cleanup requires --yes.") }
        print(permanent ? "Type DELETE to continue: " : "Type TRASH to continue: ", terminator: "")
        guard readLine() == (permanent ? "DELETE" : "TRASH") else { print("Cancelled."); exit(0) }
    }
    let result = cleaner.clean(chosen, permanently: permanent, processes: try Cleaner.runningProcesses())
    print("\(permanent ? "Deleted" : "Moved to Trash"): \(result.count) items, \(formattedBytes(result.bytes)) estimated.")
    result.errors.forEach { print("Skipped: " + $0.rendered()) }
    if !result.errors.isEmpty { exit(1) }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
