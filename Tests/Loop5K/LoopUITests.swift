import Foundation
import XCTest

@MainActor
final class LoopUITests: XCTestCase {
    private let app = XCUIApplication()

    private func parameter(_ key: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[key], "Eseguire lo schema Anello 5 km su My Mac")
    }

    private func mailbox() throws -> URL {
        let directory = URL.cachesDirectory.appending(path: try parameter("LOOP_CASE"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func signal(_ name: String, value: String = "") throws {
        try Data(value.utf8).write(to: mailbox().appending(path: name), options: .atomic)
    }

    private func awaitSignal(_ name: String, timeout: TimeInterval) throws {
        let file = try mailbox().appending(path: name)
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: file.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: timeout), .completed, name)
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    private func tap(_ element: XCUIElement) {
        #if os(watchOS)
        for _ in 0..<12 {
            if element.exists && element.isHittable && element.frame.midY > 44 &&
                element.frame.midY < app.frame.height - 14 { break }
            let up = !element.exists || element.frame.midY >= app.frame.height - 14
            let start = app.coordinate(withNormalizedOffset: .init(dx: 0.92, dy: up ? 0.89 : 0.32))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.92, dy: up ? 0.32 : 0.89)))
        }
        #endif
        XCTAssertTrue(element.waitForExistence(timeout: 15), element.debugDescription)
        element.tap()
    }

    #if os(iOS)
    func testCreateAndSend() throws {
        app.launch()
        tap(app.buttons["library.newRoute"])
        tap(app.buttons["Ad anello"])
        tap(app.buttons["route.useLocation"])
        let stepper = app.steppers["route.targetDistance"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 12))
        let plus = stepper.buttons.allElementsBoundByIndex.last
        for _ in 0..<2 { tap(try XCTUnwrap(plus)) } // Default 4 km, steps of 500 m.
        let generate = app.buttons["route.generateLoop"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: generate)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed)
        tap(generate)
        XCTAssertTrue(app.staticTexts["route.distance"].waitForExistence(timeout: 90), app.debugDescription)
        let alternatives = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'route.alternative.'"))
        let options = alternatives.allElementsBoundByIndex.compactMap { option -> (XCUIElement, Double)? in
            let units = option.label.split(whereSeparator: { $0.isWhitespace }).suffix(2)
            guard units.last == "km", let number = units.first,
                  let km = Double(number.replacingOccurrences(of: ",", with: ".")) else { return nil }
            return (option, abs(km - 5))
        }
        if let nearest = options.min(by: { $0.1 < $1.1 }), !nearest.0.isSelected { tap(nearest.0) }
        tap(app.buttons["route.save"])
        let dialog = app.alerts.firstMatch
        let field = dialog.textFields.firstMatch
        tap(field)
        if let current = field.value as? String, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(try parameter("LOOP_CASE"))
        tap(dialog.buttons["Salva"])
        tap(app.buttons["Invia al Watch"])
        XCTAssertTrue(app.buttons["Disponibile sul Watch"].waitForExistence(timeout: 45), app.debugDescription)
    }

    func testHistoryAndExport() throws {
        app.launch()
        tap(app.buttons["Allenamenti"].firstMatch)
        let rows = app.buttons.matching(identifier: "history.workout." + (try parameter("LOOP_WORKOUT")))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertEqual(rows.count, 1)
        tap(rows.firstMatch)
        let active = app.descendants(matching: .any).matching(identifier: "history.duration").firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 8))
        try signal("history-time", value: active.label)
        let export = app.buttons["Esporta GPX"]
        for _ in 0..<6 {
            if export.exists && export.isHittable { break }
            let edge = app.coordinate(withNormalizedOffset: .init(dx: 0.96, dy: 0.84))
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.96, dy: 0.42)))
        }
        XCTAssertTrue(export.exists && export.isHittable, app.debugDescription)
        tap(export)
        try signal("exporting")
        try awaitSignal("copied", timeout: 45)
    }
    #else
    func testDiscardInterruptedTestRun() throws {
        app.activate()
        let name = try parameter("LOOP_CASE")
        XCTAssertTrue(name.hasPrefix("Loop5K-"))
        try signal("discard-request")
        try awaitSignal("owned", timeout: 25)
        tap(app.buttons["Termina"])
        tap(app.buttons["Scarta senza salvare"])
        tap(app.buttons["Scarta corsa"])
        tap(app.buttons["run.done"])
    }

    func testRecordOffline() throws {
        executionTimeAllowance = 1200
        app.launch()
        let route = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", try parameter("LOOP_CASE"))).firstMatch
        tap(route)
        let start = app.buttons["Inizia corsa"]
        XCTAssertTrue(start.exists)
        try signal("ready")
        try awaitSignal("offline", timeout: 90)
        tap(start)
        let pause = app.buttons["Pausa"]
        XCTAssertTrue(pause.waitForExistence(timeout: 45), "Verificare i permessi GPS e Salute sul Watch. " + app.debugDescription)
        tap(pause)
        let resume = app.buttons["Riprendi"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        try signal("paused", value: String(Date.now.timeIntervalSince1970))
        try awaitSignal("resume", timeout: 40)
        tap(resume)
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        try signal("running", value: String(Date.now.timeIntervalSince1970))
        try awaitSignal("arrived", timeout: 950)
        tap(pause)
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        try signal("final-pause", value: String(Date.now.timeIntervalSince1970))
        let elapsed = app.descendants(matching: .any)["run.elapsed"].firstMatch
        XCTAssertTrue(elapsed.exists)
        try signal("watch-time", value: elapsed.label)
        tap(app.buttons["Termina"])
        tap(app.buttons["Salva corsa"])
        let done = app.buttons["run.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 45), app.debugDescription)
        tap(done)
    }
    #endif
}
