//
//  TwendeUITests.swift
//  TwendeUITests
//
//  Created by Rork on September 17, 2026.
//

import XCTest

final class TwendeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it's important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testFreshLaunchReachesInteractiveOnboarding() {
        let app = XCUIApplication()
        // Argument-domain defaults are process-local; no clearing existing passenger data.
        app.launchArguments = ["-twende.settings.onboardingStage", "language", "-twende.settings.language", "en"]
        app.launch()
        defer { app.terminate() }

        let next = app.buttons["onboarding.language.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "Startup must leave the blank launch screen")
        XCTAssertTrue(next.isHittable)
        next.tap()
        XCTAssertTrue(app.staticTexts["onboarding.phone"].waitForExistence(timeout: 5))
        // Entry relies on the in-app keypad, so it must work without any system keyboard.
        let sevenKey = app.buttons["keypad.7"]
        XCTAssertTrue(sevenKey.waitForExistence(timeout: 5))
        XCTAssertTrue(sevenKey.isHittable)
        sevenKey.tap()
        XCTAssertEqual(app.staticTexts["onboarding.phone"].label, "7")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testReturningLaunchReachesHomeAndOpensDestinationSearch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-twende.settings.onboardingStage", "done", "-twende.settings.language", "en",
            "-twende.activeTrip.v1", "", "-twende.passenger.v1", ""
        ]
        app.launch()
        defer { app.terminate() }

        let search = app.buttons["home.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Home must appear with live vehicle annotations")
        XCTAssertTrue(search.isHittable)
        let location = app.buttons["home.recentre"]
        XCTAssertTrue(location.isHittable)
        XCTAssertLessThan(search.frame.minY - location.frame.maxY, 180, "Recenter stays close to the sheet, not above a duplicate bottom inset")
        let homeContent = app.scrollViews["home.sheet.content"]
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 5) else { return XCTFail("Home tabs missing before any sheet interaction") }
        XCTAssertGreaterThan(homeContent.frame.maxY, tabBar.frame.minY + 20, "Detached card must extend under the tabs, not float above them")
        let initialSearchY = search.frame.minY
        // The header is directly above the floating search; its nested service labels are not a single accessibility element.
        let dragStart = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: search.frame.minY - 30))
        dragStart.press(forDuration: 0.1, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: -150)))
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in search.frame.minY < initialSearchY - 60 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 4), .completed, "Header drag must expand the viewport")
        let collapseStart = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: search.frame.minY - 30))
        collapseStart.press(forDuration: 0.1, thenDragTo: collapseStart.withOffset(CGVector(dx: 0, dy: 160)))
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(search.frame.minY - initialSearchY) < 15 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 4), .completed, "Downward drag must return to the detached detent")
        let airport = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "JNIA Terminal 3")).firstMatch
        for _ in 0..<5 {
            if airport.isHittable { break }
            guard tabBar.exists else { return XCTFail("A content drag navigated away from Home instead of expanding/scrolling the sheet") }
            let tabTop = tabBar.frame.minY
            let y = min(homeContent.frame.maxY - 20, tabTop - 24)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: y))
            let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: max(search.frame.maxY + 20, y - 130)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(airport.isHittable, "Last content remains reachable above the tab bar: \(airport.frame), scroll \(homeContent.frame), search \(search.frame)")
        XCTAssertTrue(search.isHittable, "Floating search remains tappable after scrolling beneath it")
        search.tap()
        XCTAssertTrue(app.textFields["booking.destination"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testRideOptionsCollapsePreservesSelectedTierAndCheckout() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-twende.settings.onboardingStage", "done", "-twende.settings.language", "en",
            "-twende.settings.hasSeenZeroCommission", "YES",
            "-twende.activeTrip.v1", "", "-twende.passenger.v1", ""
        ]
        app.launch()
        defer { app.terminate() }
        let search = app.buttons["home.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Home search missing")
        search.tap()
        let place = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mikocheni")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 8), "Destination suggestion missing")
        place.tap()
        let confirm = app.buttons["booking.confirmPickup"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), "Confirm pickup missing")
        confirm.tap()

        let options = app.scrollViews["rideOptions.list"]
        XCTAssertTrue(options.waitForExistence(timeout: 8), "Ride options list missing")
        let payment = app.buttons["rideOptions.payment"]
        let request = app.buttons["rideOptions.request"]
        XCTAssertTrue(payment.isHittable, "Payment not reachable")
        XCTAssertTrue(request.isHittable, "Request not reachable")
        let comfort = app.buttons["rideOptions.tier.comfort"]
        XCTAssertTrue(comfort.isHittable, "Comfort not reachable")
        comfort.tap()
        XCTAssertTrue(comfort.isSelected, "Comfort selection missing")
        let premium = app.buttons["rideOptions.tier.premium"]
        for _ in 0..<4 {
            if premium.isHittable && premium.frame.maxY <= options.frame.maxY { break }
            options.swipeUp()
        }
        XCTAssertTrue(premium.isHittable, "Premium not reachable")
        premium.tap()
        XCTAssertTrue(premium.isSelected, "Premium selection missing")
        let premiumToggle = app.buttons["rideOptions.toggle"]
        premiumToggle.tap()
        XCTAssertTrue(app.buttons["More ride options"].waitForExistence(timeout: 5), "Grabber did not collapse: \(app.buttons["rideOptions.toggle"].label)")
        XCTAssertTrue(premium.isSelected, "Premium selection missing")
        XCTAssertFalse(comfort.exists, "Collapsed Premium must not substitute the Comfort sedan")
        XCTAssertTrue(payment.isHittable, "Payment not reachable")
        XCTAssertTrue(request.isHittable, "Request not reachable")
        premiumToggle.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5), "Options did not expand")

        let bajaji = app.buttons["rideOptions.tier.bajaji"]
        for _ in 0..<4 {
            if bajaji.isHittable && bajaji.frame.maxY <= options.frame.maxY { break }
            options.swipeUp()
        }
        XCTAssertTrue(bajaji.isHittable, "Bajaji not reachable")
        bajaji.tap()
        XCTAssertTrue(bajaji.isSelected, "Bajaji selection missing")

        let pickupBanner = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Pickup in ")).firstMatch
        let dropoffBanner = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Drop-off at ")).firstMatch
        XCTAssertTrue(pickupBanner.waitForExistence(timeout: 10), "Pickup banner missing")
        XCTAssertTrue(dropoffBanner.waitForExistence(timeout: 10), "Dropoff banner missing")

        let toggle = app.buttons["rideOptions.toggle"]
        toggle.tap()
        XCTAssertTrue(app.buttons["More ride options"].waitForExistence(timeout: 5), "Grabber did not collapse: \(app.buttons["rideOptions.toggle"].label)")
        XCTAssertTrue(app.buttons["rideOptions.tier.bajaji"].isSelected)
        XCTAssertFalse(app.buttons["rideOptions.tier.economy"].exists)
        XCTAssertFalse(app.buttons["rideOptions.tier.comfort"].exists)
        XCTAssertFalse(app.buttons["rideOptions.tier.premium"].exists)
        XCTAssertFalse(app.buttons["rideOptions.tier.boda"].exists)
        XCTAssertTrue(payment.isHittable, "Payment not reachable")
        XCTAssertTrue(request.isHittable, "Request not reachable")
        XCTAssertTrue(app.frame.contains(payment.frame))
        XCTAssertTrue(app.frame.contains(request.frame))

        // Expanding by drag must not change the selected ride or consume footer taps.
        let start = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)))
        XCTAssertTrue(options.waitForExistence(timeout: 5), "Options did not expand")
        XCTAssertTrue(payment.isHittable, "Payment not reachable")
        XCTAssertTrue(request.isHittable, "Request not reachable")
        toggle.tap()
        XCTAssertTrue(app.buttons["More ride options"].waitForExistence(timeout: 5), "Grabber did not collapse: \(app.buttons["rideOptions.toggle"].label)")
        payment.tap()
        XCTAssertTrue(app.staticTexts["Pay with"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testStopsReorderInsideSearchWithoutAnotherSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-twende.settings.onboardingStage", "done", "-twende.settings.language", "en", "-twende.activeTrip.v1", "", "-twende.passenger.v1", ""]
        app.launch()
        defer { app.terminate() }
        let search = app.buttons["home.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Home search missing")
        search.tap()
        let place = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mikocheni")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 8), "Destination suggestion missing")
        place.tap()
        let reorder = app.buttons["route.reorder"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 8))
        reorder.tap()
        let inline = app.descendants(matching: .any).matching(identifier: "route.inline").firstMatch
        XCTAssertTrue(inline.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["route.order.save"].exists)
        let source = inline.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.75))
        let target = inline.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.15))
        source.press(forDuration: 0.5, thenDragTo: target)
        let first = app.descendants(matching: .any).matching(identifier: "route.order.0").firstMatch
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Mikocheni"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["route.continue"].isHittable)
        app.buttons["route.continue"].tap()
        XCTAssertTrue(app.buttons["booking.confirmPickup"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
