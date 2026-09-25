import XCTest
@testable import MellowCore

final class CleanerTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default
    let old = Date().addingTimeInterval(-40 * 86_400)
    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: try XCTUnwrap(physicalPath(home)))
    }
    override func tearDownWithError() throws { try fm.removeItem(at: home) }
    func file(_ relative: String, age: Bool = true) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: 4096).write(to: url)
        if age { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        return url
    }
    func testOnlyOldAllowlistedFilesCanBeDeleted() throws {
        let cache = try file("Library/Caches/Homebrew/downloads/old.tar.gz")
        let recent = try file("Library/Caches/Homebrew/downloads/recent.tar.gz", age: false)
        let personal = try file("Documents/important.txt")
        let cleaner = Cleaner(home: home)
        let scan = cleaner.scan(processes: [])
        XCTAssertEqual(scan.candidates.map(\.path), [cache.path])
        let result = cleaner.clean(scan.candidates, permanently: true, processes: [])
        XCTAssertEqual(result.count, 1, result.errors.map { $0.rendered() }.joined(separator: "; "))
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        XCTAssertTrue(fm.fileExists(atPath: recent.path))
        XCTAssertTrue(fm.fileExists(atPath: personal.path))
    }
    func testBusyApplicationBlocksScanAndCleanup() throws {
        let cache = try file("Library/Caches/Homebrew/downloads/a")
        let cleaner = Cleaner(home: home)
        XCTAssertTrue(cleaner.scan(processes: ["ruby"]).candidates.isEmpty)
        let result = cleaner.clean(cleaner.scan(processes: []).candidates, permanently: true, processes: ["brew"])
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
    }
    func testChangedFileIsNotDeleted() throws {
        let cache = try file("Library/Caches/Homebrew/downloads/a")
        let cleaner = Cleaner(home: home)
        let scan = cleaner.scan(processes: [])
        try Data("changed".utf8).write(to: cache)
        let result = cleaner.clean(scan.candidates, permanently: true, processes: [])
        XCTAssertEqual(result.count, 0)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
    }
    func testSymlinksAndRedirectedRootsAreProtected() throws {
        let personal = try file("Documents/important.txt")
        let root = home.appendingPathComponent("Library/Caches/Homebrew/downloads")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: personal)
        XCTAssertTrue(Cleaner(home: home).scan(processes: []).candidates.isEmpty)
        try fm.removeItem(at: root)
        try fm.createSymbolicLink(at: root, withDestinationURL: personal.deletingLastPathComponent())
        XCTAssertTrue(Cleaner(home: home).scan(processes: []).candidates.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: personal.path))
    }
    func testForgedAndDuplicateCandidates() throws {
        let personal = try file("Documents/important.txt")
        let cleaner = Cleaner(home: home)
        let forged = Candidate(categoryID: "homebrew", path: personal.path, bytes: 4096, fingerprint: "fake")
        XCTAssertEqual(cleaner.clean([forged], permanently: true, processes: []).count, 0)
        XCTAssertTrue(fm.fileExists(atPath: personal.path))
        _ = try file("Library/Caches/Homebrew/downloads/a")
        let scan = cleaner.scan(processes: [])
        XCTAssertEqual(cleaner.clean(scan.candidates + scan.candidates, permanently: true, processes: []).count, 1)
    }
    func testRecentChildProtectsOldDirectory() throws {
        let recent = try file("Library/Developer/Xcode/DerivedData/project/recent", age: false)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: recent.deletingLastPathComponent().path)
        XCTAssertTrue(Cleaner(home: home).scan(processes: []).candidates.isEmpty)
    }
    func testHardLinksAreProtected() throws {
        let personal = try file("Documents/important.txt")
        let cache = home.appendingPathComponent("Library/Caches/Homebrew/downloads/link")
        try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.linkItem(at: personal, to: cache)
        XCTAssertTrue(Cleaner(home: home).scan(processes: []).candidates.isEmpty)
    }
}
