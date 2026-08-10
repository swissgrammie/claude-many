import XCTest
@testable import claude_many

final class ProfileStoreTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-many-store-\(UUID().uuidString)", isDirectory: true)
        storeURL = tempDir.appendingPathComponent("profiles.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadMissingFileReturnsEmpty() throws {
        let store = ProfileStore(fileURL: storeURL)
        XCTAssertEqual(try store.load(), [])
    }

    func testSaveAndLoadRoundTrip() throws {
        let dir = tempDir.appendingPathComponent("Profiles/one", isDirectory: true)
        let original = [
            ClaudeProfile(label: "One", dataDirectory: dir),
            ClaudeProfile(label: "Two", dataDirectory: tempDir.appendingPathComponent("Profiles/two", isDirectory: true)),
        ]
        let store = ProfileStore(fileURL: storeURL)
        try store.save(original)

        let loaded = try ProfileStore(fileURL: storeURL).load()
        XCTAssertEqual(loaded, original)
    }

    func testLoadPreservesDataDirectoryPathsExactly() throws {
        let path = "/tmp/custom place/with space/Profiles/工作"
        let profile = ClaudeProfile(label: "Work", dataDirectory: URL(fileURLWithPath: path, isDirectory: true))
        let store = ProfileStore(fileURL: storeURL)
        try store.save([profile])

        let loaded = try ProfileStore(fileURL: storeURL).load()
        XCTAssertEqual(loaded.first?.dataDirectory.path, path)
    }

    func testLoadThrowsOnCorruptData() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: storeURL.path, contents: Data("not json {".utf8))
        let store = ProfileStore(fileURL: storeURL)
        XCTAssertThrowsError(try store.load())
    }

    func testSaveOverwritesPreviousContents() throws {
        let store = ProfileStore(fileURL: storeURL)
        try store.save([ClaudeProfile(label: "A", dataDirectory: tempDir.appendingPathComponent("a"))])
        try store.save([ClaudeProfile(label: "B", dataDirectory: tempDir.appendingPathComponent("b"))])
        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.label), ["B"])
    }
}
