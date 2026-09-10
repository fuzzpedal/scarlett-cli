import XCTest
@testable import ScarlettAudio

final class SaveCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var cacheURL: URL {
        directory.appendingPathComponent("last-saved.json")
    }

    func test_roundTripsAnEntry() throws {
        let entry = LastSaved(source: "S/PDIF", savedAt: Date(timeIntervalSince1970: 1_789_000_000))
        try SaveCache.write(entry, to: cacheURL)
        XCTAssertEqual(SaveCache.read(from: cacheURL), entry)
    }

    func test_createsIntermediateDirectories() throws {
        let nested = directory.appendingPathComponent("a/b/last-saved.json")
        try SaveCache.write(LastSaved(source: "ADAT", savedAt: Date()), to: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func test_missingFileReadsAsNil() {
        XCTAssertNil(SaveCache.read(from: cacheURL))
    }

    func test_malformedFileReadsAsNilRatherThanThrowing() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: cacheURL)
        XCTAssertNil(SaveCache.read(from: cacheURL))
    }
}
