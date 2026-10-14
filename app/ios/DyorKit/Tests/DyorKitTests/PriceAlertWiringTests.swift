import XCTest
@testable import DyorKit

/// The price alerts in the app: the target field is read with `PriceAlertTarget.parse` (the amount fields' parser),
/// it is wide enough for a dust target, and the list and the notification show prices in the one style.
final class PriceAlertWiringTests: XCTestCase {
    /// The app reads the target with `PriceAlertTarget.parse`, never `Double(targetText)`, and the list and the
    /// notification show it in the one price style.
    func testTargetParsingAndDisplay() throws {
        let alerts = try DocsLinksTests.appSource("Wallet/PriceAlerts.swift")
        XCTAssertTrue(alerts.contains("private var target: Double? { PriceAlertTarget.parse(targetText) }"))
        XCTAssertFalse(alerts.contains("Double(targetText)"))
        XCTAssertTrue(alerts.contains("\\(PriceFormat.usdPrice(alert.target))"))
        // The direction is part of each sentence (a key of its own), never a word put into another one.
        XCTAssertTrue(alerts.contains(".accessibilityLabel(alert.above ? \"Above \\(PriceFormat.spoken(alert.target))\" : \"Below \\(PriceFormat.spoken(alert.target))\")"))
        XCTAssertTrue(alerts.contains(".frame(maxWidth: 220).layoutPriority(1)"), "the field widens for a dust target")
        XCTAssertTrue(alerts.contains("Text(\"Target\").fixedSize()"), "the wider field never cuts the Target label short")
        XCTAssertTrue(alerts.contains("Text(\"USD\").foregroundStyle(.secondary).fixedSize()"), "nor the USD label")
        XCTAssertFalse(alerts.contains("minWidth: 120"), "no minimum width that pushes the row past the edge at large text sizes")
        XCTAssertFalse(alerts.contains("NumberStyle."), "no second number style on the alerts screen")
        let notifications = try DocsLinksTests.appSource("Wallet/Notifications.swift")
        XCTAssertTrue(notifications.contains("let now = PriceFormat.usdPrice(price)"))
        XCTAssertTrue(notifications.contains("let goal = PriceFormat.usdPrice(target)"))
        XCTAssertTrue(notifications.contains("tr(\"\\(symbol) is now \\(now) — above your \\(goal) target.\") : tr(\"\\(symbol) is now \\(now) — below your \\(goal) target.\")"))
    }
}
