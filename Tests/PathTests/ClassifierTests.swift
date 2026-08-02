import Foundation
import XCTest
@testable import path

final class ClassifierTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testClassifiesShebangAndRelativeSymlink() throws {
        let script = directory.appendingPathComponent("script")
        try "#!/usr/bin/env python3\nprint('ok')\n".write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        let link = directory.appendingPathComponent("linked-script")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: script.lastPathComponent
        )

        let classification = Classifier.classify(link.path)

        XCTAssertEqual(classification.type, .script)
        XCTAssertEqual(classification.lang, "python")
    }

    func testTruncatedMachOIsHandledWithoutCrashing() throws {
        let binary = directory.appendingPathComponent("truncated")
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: binary)

        XCTAssertNil(MachO.detectLanguage(at: binary.path))
        XCTAssertEqual(Classifier.classify(binary.path).type, .binary)
    }
}
