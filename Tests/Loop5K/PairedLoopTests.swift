import Foundation
import XCTest

final class PairedLoopTests: XCTestCase {
    func testFiveKilometreLoopAfterReconnect() throws {
        executionTimeAllowance = 1800
        let output = FileManager.default.temporaryDirectory.appending(path: "Runloop-5km-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "paired_loop.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", script.path, output.path]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("DYLD_") || key.hasPrefix("XCTest") {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        let log = output.appending(path: "test.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        print("Risultati anello 5 km: " + output.path)
        try process.run()
        process.waitUntilExit()
        try handle.close()
        for name in ["test.log", "risultato.json", "corsa.gpx"] {
            let file = output.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path) {
                let attachment = XCTAttachment(contentsOfFile: file)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let details = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, String(details.suffix(6000)))
    }
}
