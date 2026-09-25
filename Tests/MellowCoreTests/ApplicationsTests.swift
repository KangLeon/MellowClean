import XCTest
@testable import MellowCore

final class ApplicationsTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try XCTUnwrap(physicalPath(root)))
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func app(_ name: String = "Sample", id: String = "test.mellowclean.sample") throws -> URL {
        let url = root.appendingPathComponent(name + ".app")
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id, "CFBundleName": name], format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func testBlocksProtectedRunningAndChangedApplications() throws {
        let cleaner = ApplicationUninstaller(roots: [root])
        for id in ["com.apple.Safari", "io.github.kangleon.mellowclean"] {
            let url = try app(id, id: id)
            let item = try cleaner.inspect(url, running: [])
            XCTAssertNotNil(item.blocked)
            XCTAssertThrowsError(try cleaner.validate(item, running: []))
        }
        let url = try app()
        let item = try cleaner.inspect(url, running: [])
        XCTAssertNil(item.blocked)
        XCTAssertNoThrow(try cleaner.validate(item, running: []))
        XCTAssertThrowsError(try cleaner.validate(item, running: [url]))
        XCTAssertThrowsError(try cleaner.validate(item, running: [url.appendingPathComponent("Contents/MacOS/Helper")]))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        XCTAssertThrowsError(try cleaner.validate(item, running: []))
        XCTAssertTrue(fm.fileExists(atPath: url.path))
    }

    func testRejectsLinksOutsideRootsAndMalformedBundles() throws {
        let url = try app()
        let cleaner = ApplicationUninstaller(roots: [root])
        let link = root.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try cleaner.inspect(link, running: []))
        XCTAssertThrowsError(try ApplicationUninstaller(roots: []).inspect(url, running: []))
        let info = url.appendingPathComponent("Contents/Info.plist")
        let saved = root.appendingPathComponent("saved.plist")
        try fm.moveItem(at: info, to: saved)
        try fm.createSymbolicLink(at: info, withDestinationURL: saved)
        XCTAssertThrowsError(try cleaner.inspect(url, running: []))
        try fm.removeItem(at: info)
        try Data("not a plist".utf8).write(to: info)
        XCTAssertThrowsError(try cleaner.inspect(url, running: []))
    }

    func testTrashMovesOnlyDisposableBundleAndKeepsData() throws {
        let url = try app()
        let data = root.appendingPathComponent("personal-data.txt")
        try Data("keep me".utf8).write(to: data)
        let cleaner = ApplicationUninstaller(roots: [root])
        let scan = cleaner.scan()
        let item = try XCTUnwrap(scan.applications.first)
        XCTAssertEqual(item.url.path, url.path)
        let destination = try cleaner.trash(item)
        defer { try? fm.removeItem(at: destination) }
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertEqual(try String(contentsOf: data), "keep me")
        XCTAssertThrowsError(try cleaner.trash(item))
    }
}
