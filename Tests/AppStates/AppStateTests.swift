import XCTest

@MainActor
final class AppStateTests: XCTestCase {
    private let app = XCUIApplication()

    #if os(watchOS)
    private let system = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
    private let newRoute = "watch.library.newRoute"
    #else
    private let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let newRoute = "library.newRoute"
    #endif

    override func setUpWithError() throws { continueAfterFailure = false }

    private func evidence(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func show(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<16 {
            let frame = element.exists ? element.frame : .null
            #if os(watchOS)
            let top = 40.0, bottom = app.frame.height - 14
            #else
            let top = 55.0, bottom = app.frame.height - 24
            #endif
            if !frame.isNull, element.isHittable, (top...bottom).contains(frame.midY) { return }
            let down = frame.isNull || frame.midY >= bottom
            #if os(watchOS)
            // Stay in the scroll margin so that a drag never pans the route map.
            let x = 0.025
            #else
            let x = 0.93
            #endif
            let edge = app.coordinate(withNormalizedOffset: .init(dx: x, dy: down ? 0.84 : 0.35))
            edge.press(forDuration: 0.07, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: x, dy: down ? 0.41 : 0.80)), withVelocity: 180, thenHoldForDuration: 0.25)
        }
        XCTFail("Comando fuori portata: " + element.description + "\n" + app.debugDescription, file: file, line: line)
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        show(element, file: file, line: line)
        XCTAssertTrue(element.isEnabled, file: file, line: line)
        element.tap()
    }

    private func enterFreeRun() {
        #if os(watchOS)
        tap(app.buttons["Corsa libera"])
        #else
        tap(app.buttons["run.free"])
        let phone = app.buttons["Usa iPhone"]
        if phone.waitForExistence(timeout: 4) { tap(phone) }
        #endif
    }

    // Start on a clean simulator with Location Services undecided.
    func testFirstLaunchAndDenyGPS() {
        app.launch()
        let deny = NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "Non consentire"])
        let systemChoice = system.buttons.matching(deny).firstMatch
        let appChoice = app.buttons.matching(deny).firstMatch
        XCTAssertTrue(systemChoice.waitForExistence(timeout: 12) || appChoice.exists,
                      system.debugDescription + app.debugDescription)
        evidence("Primo avvio e richiesta GPS")
        (systemChoice.exists ? systemChoice : appChoice).tap()
        XCTAssertTrue(app.buttons[newRoute].waitForExistence(timeout: 15), app.debugDescription)
        evidence("Libreria al primo avvio")
        enterFreeRun()
        let cancel = app.buttons["Annulla"]
        XCTAssertTrue(app.buttons["Corri senza GPS"].waitForExistence(timeout: 12), app.debugDescription)
        evidence("GPS negato prima della corsa")
        tap(cancel)
        tap(app.buttons[newRoute])
        #if os(watchOS)
        tap(app.buttons["watch.route.location"])
        let message = app.staticTexts["watch.route.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 6) && message.label.contains("Impostazioni"))
        tap(app.buttons["watch.route.center"])
        XCTAssertFalse(message.exists)
        #else
        tap(app.buttons["route.useLocation"])
        let message = app.staticTexts["route.locationStatus"]
        XCTAssertTrue(message.waitForExistence(timeout: 6) && message.label.contains("disattivato"), app.debugDescription)
        XCTAssertTrue(app.buttons["route.locationSettings"].exists)
        tap(app.buttons["route.useCenter"])
        XCTAssertFalse(message.exists)
        #endif
        evidence("Partenza manuale con GPS negato")
        app.launch()
        XCTAssertTrue(app.buttons[newRoute].waitForExistence(timeout: 12))
        XCTAssertFalse(systemChoice.exists || appChoice.exists, "La scelta GPS deve sopravvivere al riavvio")
    }

    // Location denied and Health permission already granted on the simulator.
    func testRunWithoutGPS() throws {
        #if os(watchOS)
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        #endif
        app.launch()
        enterFreeRun()
        tap(app.buttons["Corri senza GPS"])
        let pause = app.buttons["Pausa"]
        XCTAssertTrue(pause.waitForExistence(timeout: 35), app.debugDescription)
        tap(pause)
        let elapsed = app.descendants(matching: .any)["run.elapsed"].firstMatch
        XCTAssertTrue(elapsed.exists && elapsed.label.localizedCaseInsensitiveContains("pausa"))
        XCTAssertTrue(elapsed.label.contains("tempo attivo"))
        #if os(watchOS)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "passo medio non disponibile")).firstMatch.exists)
        #endif
        show(elapsed)
        evidence("Timer in pausa senza GPS")
        #if os(watchOS)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .textClipped, .trait])
        #endif
        tap(app.buttons["Riprendi"])
        tap(app.buttons["Termina"])
        tap(app.buttons["Scarta senza salvare"])
        tap(app.buttons["Scarta corsa"])
        tap(app.buttons["run.done"])
        app.launch()
        let library = app.buttons[newRoute]
        XCTAssertTrue(library.waitForExistence(timeout: 15), app.debugDescription)
        // Exercise a second start after HealthKit has had the opportunity to deliver recovery.
        enterFreeRun()
        XCTAssertTrue(app.buttons["Corri senza GPS"].waitForExistence(timeout: 12), app.debugDescription)
        tap(app.buttons["Annulla"])
        XCTAssertTrue(library.waitForExistence(timeout: 10), app.debugDescription)
    }

    // The host restores the actual routing provider after observing the failure.
    func testRouteServiceRecovery() throws {
        try checkRecovery(companionOffline: false)
    }

    #if os(watchOS)
    func testCompanionRecovery() throws {
        try checkRecovery(companionOffline: true)
    }
    #endif

    private func checkRecovery(companionOffline: Bool) throws {
        let run = try XCTUnwrap(ProcessInfo.processInfo.environment["RUNLOOP_QA_CASE"])
        app.launch()
        #if os(watchOS)
        if companionOffline {
            let cached = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.library.route.'")).firstMatch
            tap(cached)
            tap(app.buttons["Mostra traccia"])
            let trace = app.staticTexts["Traccia del percorso disponibile offline"]
            XCTAssertTrue(trace.exists)
            show(trace)
            evidence("Percorso salvato con iPhone spento")
            app.buttons["BackButton"].tap()
        }
        #endif
        tap(app.buttons[newRoute])
        #if os(watchOS)
        let center = app.buttons["watch.route.center"]
        let generate = app.buttons["watch.route.generate"]
        let message = app.staticTexts["watch.route.message"]
        let distance = app.staticTexts["watch.route.distance"]
        #else
        tap(app.buttons["Ad anello"])
        let center = app.buttons["route.useCenter"]
        let generate = app.buttons["route.generateLoop"]
        let message = app.staticTexts["route.routingStatus"]
        let distance = app.staticTexts["route.distance"]
        #endif
        tap(center)
        tap(generate)
        XCTAssertTrue(message.waitForExistence(timeout: companionOffline ? 10 : 70), app.debugDescription)
        let expected = companionOffline ? "iPhone" : "Servizio percorsi temporaneamente non disponibile"
        XCTAssertTrue(message.label.contains(expected), message.label)
        show(message)
        evidence(companionOffline ? "iPhone scollegato" : "Servizio percorsi offline")
        let cache = URL.cachesDirectory
        try Data().write(to: cache.appending(path: run + "-offline"))
        let restored = cache.appending(path: run + "-online")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: restored.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 150), .completed)
        #if os(watchOS)
        if companionOffline {
            let connected = app.staticTexts["watch.route.reconnected"]
            XCTAssertTrue(connected.waitForExistence(timeout: 75), app.debugDescription)
            XCTAssertTrue(generate.label.contains("Riprova"))
            show(connected)
            evidence("Riconnessione confermata dal Watch")
        }
        #endif
        tap(generate)
        XCTAssertTrue(distance.waitForExistence(timeout: 95), app.debugDescription)
        XCTAssertTrue(distance.label.contains("km"))
        XCTAssertFalse(message.exists)
        show(distance)
        evidence("Stessa partenza dopo la riconnessione")
    }

    #if os(watchOS)
    func testLargeTextAndAccessibleControls() throws {
        app.launch()
        let title = app.staticTexts["Percorsi"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        let normalHeight = title.frame.height
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(title.frame.height, normalHeight, "La preferenza deve ingrandire il testo sul Watch")
        evidence("Libreria con caratteri grandi")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .textClipped, .trait])
        let create = app.buttons[newRoute]
        XCTAssertEqual(create.label, "Nuovo percorso")
        tap(create)
        let manual = app.buttons["watch.route.manual"], loop = app.buttons["watch.route.loop"]
        let modeOrder = app.buttons.allElementsBoundByAccessibilityElement.map(\.identifier).filter {
            $0 == "watch.route.manual" || $0 == "watch.route.loop"
        }
        XCTAssertEqual(modeOrder, ["watch.route.manual", "watch.route.loop"])
        XCTAssertTrue(loop.isSelected)
        tap(manual)
        XCTAssertTrue(manual.isSelected && !loop.isSelected)
        tap(loop)
        let center = app.buttons["watch.route.center"]
        XCTAssertEqual(center.label, "Usa il centro della mappa")
        tap(center)
        let plus = app.buttons["Aumenta obiettivo"]
        let adjustmentOrder = app.buttons.allElementsBoundByAccessibilityElement.map(\.label).filter {
            $0 == "Riduci obiettivo" || $0 == "Aumenta obiettivo"
        }
        XCTAssertEqual(adjustmentOrder, ["Riduci obiettivo", "Aumenta obiettivo"])
        tap(plus)
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Obiettivo' AND label CONTAINS '6'")).firstMatch
        XCTAssertTrue(target.exists, app.debugDescription)
        show(plus)
        evidence("Obiettivo con caratteri grandi")
        try app.performAccessibilityAudit(for: [.textClipped, .sufficientElementDescription, .trait])
    }
    #endif
}
