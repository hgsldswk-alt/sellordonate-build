import XCTest

final class FlowUITests: XCTestCase {
    private enum StoreLanguage: String, CaseIterable {
        case english = "en"
        case simplified = "zh-Hans"
        case traditional = "zh-Hant"

        var locale: String {
            switch self {
            case .english: return "en_US"
            case .simplified: return "zh_CN"
            case .traditional: return "zh_TW"
            }
        }
    }

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ args: [String] = [], language: StoreLanguage = .simplified,
                        reset: Bool = true, code: String? = nil) {
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language.rawValue))",
                               "-AppleLocale", language.locale, "-currency", "CNY"]
            + (reset ? ["-reset"] : []) + args
        app.launchEnvironment = code.map { ["SD_TEST_CODE": $0] } ?? [:]
        app.launch()
        XCTAssertTrue(app.textFields["field.price"].waitForExistence(timeout: 10))
    }

    private func button(_ id: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: id)
        return matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
    }

    private func tap(_ id: String, scroll: Bool = false) {
        let deadline = Date().addingTimeInterval(7)
        var element = button(id)
        repeat {
            element = button(id)
            if element.exists && element.isHittable && element.isEnabled {
                element.tap()
                return
            }
            if scroll && element.exists && !element.isHittable {
                app.scrollViews.firstMatch.swipeUp()
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
        } while Date() < deadline
        XCTFail("Cannot tap \(id)")
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        if current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        if !value.isEmpty { field.typeText(value) }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPriceSaveAndChangeDestination() {
        launch()
        XCTAssertEqual(app.staticTexts["home.recommendation"].label, "先填预计卖价")
        XCTAssertFalse(button("home.addSell").isEnabled)
        let price = app.textFields["field.price"]
        price.tap()
        price.typeText("95")
        let keyboard = app.staticTexts["home.keyboardResult"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.label.contains("挂卖"))
        XCTAssertTrue(app.staticTexts["home.net"].exists)
        tap("home.addSell")
        tap("keyboard.done")
        XCTAssertEqual(price.value as? String, price.placeholderValue)
        tap("home.list")
        XCTAssertTrue(app.staticTexts["item.name.1"].waitForExistence(timeout: 5))
        tap("item.route.1")
        app.buttons["改为待捐"].firstMatch.tap()
        tap("session.filter.donate")
        XCTAssertTrue(app.staticTexts["item.name.1"].exists)
        tap("item.donation.1")
        replace(app.textFields["editor.donationMinutes"], with: "4")
        tap("editor.save")
        XCTAssertTrue(button("session.share").waitForExistence(timeout: 5))
        tap("session.filter.all")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "21")).firstMatch.exists)
    }

    func testChangeDestinationToDiscarded() {
        launch()
        let price = app.textFields["field.price"]
        price.tap()
        price.typeText("95")
        tap("home.addSell")
        tap("keyboard.done")
        tap("home.list")
        tap("item.route.1")
        let discard = app.buttons["已丢弃"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()

        let status = app.staticTexts["item.status.1"]
        XCTAssertTrue(app.staticTexts["item.date.1"].waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "已丢弃")
        XCTAssertTrue(button("session.share").exists)

        app.terminate()
        launch(reset: false)
        tap("home.list")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "已丢弃")
    }

    func testContinuousThirtyAndUndo() {
        executionTimeAllowance = 300
        launch()
        let price = app.textFields["field.price"]
        price.tap()
        for _ in 0..<30 {
            price.typeText("95")
            tap("home.addSell")
            let cleared = NSPredicate(format: "value == %@", price.placeholderValue ?? "输入金额")
            let condition = XCTNSPredicateExpectation(predicate: cleared, object: price)
            XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 5), .completed)
        }
        tap("keyboard.done")
        tap("home.undo", scroll: true)
        XCTAssertEqual(price.value as? String, "95")
        tap("home.list")
        XCTAssertTrue(app.staticTexts["item.name.29"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["item.name.30"].exists)
    }

    func testDraftAndListRelaunch() {
        launch()
        let price = app.textFields["field.price"]
        price.tap()
        price.typeText("12")
        tap("home.addDonate")
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", price.placeholderValue ?? "输入金额"), object: price)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
        price.typeText("37")
        tap("keyboard.done")
        app.terminate()
        launch(reset: false)
        XCTAssertEqual(app.textFields["field.price"].value as? String, "37")
        tap("home.list")
        XCTAssertTrue(app.staticTexts["item.name.1"].waitForExistence(timeout: 5))
    }

    func testCrossCurrencyCancelAndConfirm() {
        launch(["-example-price", "95"])
        tap("home.presets", scroll: true)
        tap("preset.apply.ebay")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["取消"].tap()
        tap("sheet.close")
        XCTAssertEqual(app.textFields["field.price"].value as? String, "95")
        tap("home.presets", scroll: true)
        tap("preset.apply.ebay")
        alert.buttons["确认更换"].tap()
        XCTAssertTrue(app.textFields["field.price"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["field.price"].value as? String, "输入金额")
        XCTAssertTrue(app.textFields["field.price"].label.contains("USD"))
    }

    func testResultsShareAppearsAfterFirstSale() {
        launch(["-example-list", "-example-history"])
        tap("home.list")
        let summary = app.descendants(matching: .any)["session.summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertFalse(button("session.share").exists)
        app.navigationBars.buttons.firstMatch.tap()

        let price = app.textFields["field.price"]
        price.tap()
        price.typeText("95")
        tap("home.addSell")
        tap("keyboard.done")
        tap("home.list")
        XCTAssertTrue(app.staticTexts["item.name.1"].waitForExistence(timeout: 5))
        XCTAssertFalse(button("session.share").exists)
        tap("item.sale.1")
        replace(app.textFields["editor.actual"], with: "42")
        tap("editor.save")
        XCTAssertTrue(button("session.share").waitForExistence(timeout: 5))
    }

    func testSharePreviewAndCSVRetry() {
        launch(["-example-list"])
        tap("home.list")
        tap("session.share")
        XCTAssertTrue(app.descendants(matching: .any)["share.card"].firstMatch.waitForExistence(timeout: 6))
        tap("share.image")
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: 8))
        tap("sheet.close")
        tap("session.csv")
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: 6))
        tap("session.csv")
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: 6))
        tap("session.milestone.10")
        XCTAssertTrue(app.descendants(matching: .any)["share.card"].firstMatch.waitForExistence(timeout: 6))
    }

    func testCodePreviewApplyAndUndo() {
        let payload = #"{"version":1,"currency":"CNY","threshold":42,"minutes":35}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        launch(code: "SD1:" + encoded + "\n")
        tap("home.import", scroll: true)
        XCTAssertEqual(button("import.paste").label, "粘贴口令")
        XCTAssertFalse(button("import.apply").exists)
        tap("import.paste")
        XCTAssertTrue(app.staticTexts["import.valid"].waitForExistence(timeout: 6))
        XCTAssertFalse(button("import.preview").exists)
        tap("import.apply", scroll: true)
        XCTAssertTrue(app.textFields["field.minutes"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.textFields["field.minutes"].value as? String, "35")
        XCTAssertEqual(app.textFields["field.threshold"].value as? String, "42")
        tap("home.undo", scroll: true)
        XCTAssertEqual(app.textFields["field.minutes"].value as? String, "25")
    }

    func testBadCodeKeepsSettings() {
        launch(code: "SD1:broken\n")
        tap("home.import", scroll: true)
        tap("import.paste")
        XCTAssertTrue(app.staticTexts["import.error"].waitForExistence(timeout: 6))
        XCTAssertFalse(button("import.apply").exists)
        tap("sheet.close")
        XCTAssertEqual(app.textFields["field.minutes"].value as? String, "25")
    }

    func testManualCodeWhenPasteIsUnavailable() {
        launch()
        tap("home.import", scroll: true)
        tap("import.paste")
        XCTAssertTrue(app.staticTexts["import.error"].waitForExistence(timeout: 5))
        let payload = #"{"version":1,"currency":"CNY","threshold":42,"minutes":35}"#
        let code = "SD1:" + Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let editor = app.textViews["import.text"]
        editor.tap()
        editor.typeText(code)
        XCTAssertTrue(app.staticTexts["import.valid"].waitForExistence(timeout: 6))
        tap("import.apply", scroll: true)
        XCTAssertEqual(app.textFields["field.minutes"].value as? String, "35")
    }

    func testCurrentListContinuesAcrossDays() {
        for (index, time) in ["1795392000", "1795478400"].enumerated() {
            if index == 1 { app.terminate() }
            launch(["-example-time", time], reset: index == 0)
            let price = app.textFields["field.price"]
            price.tap()
            price.typeText("12")
            tap("home.addDonate")
            tap("keyboard.done")
            tap("home.list")
            tap("item.donation.\(index + 1)")
            tap("editor.save")
            XCTAssertTrue(app.staticTexts["item.date.\(index + 1)"].waitForExistence(timeout: 6))
        }
        XCTAssertNotEqual(app.staticTexts["item.date.1"].label, app.staticTexts["item.date.2"].label)
    }

    func testMilestone50AppearsOnce() { advancedMilestone(50) }
    func testMilestone100AppearsOnce() { advancedMilestone(100) }

    private func advancedMilestone(_ target: Int) {
        executionTimeAllowance = 600
        do {
            launch(["-example-list", "-example-count", String(target - 1)])
            let price = app.textFields["field.price"]
            price.tap()
            price.typeText("12")
            tap("home.addDonate")
            tap("keyboard.done")
            tap("home.list")
            tap("item.donation.\(target)")
            tap("editor.save")
            let milestone = "session.milestone.\(target)"
            let notice = app.staticTexts["session.milestoneNotice"]
            XCTAssertTrue(button(milestone).waitForExistence(timeout: 6))
            let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", String(target)),
                                                  object: notice)
            XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 8), .completed)
            app.terminate()
            launch(reset: false)
            tap("home.list")
            XCTAssertTrue(button(milestone).waitForExistence(timeout: 6))
            XCTAssertFalse(notice.exists)
            app.terminate()
        }
    }

    func testExpiredCanReadAndExportHistory() {
        launch(["-expired", "-example-list", "-example-history"])
        tap("home.presets", scroll: true)
        XCTAssertFalse(button("preset.apply.ebay").isEnabled)
        tap("sheet.close")
        tap("home.list")
        tap("session.history", scroll: true)
        tap("history.csv")
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: 6))
        tap("history.session")
        XCTAssertTrue(app.descendants(matching: .any)["session.summary"].firstMatch.waitForExistence(timeout: 6))
    }

    func testStoreScreenshots() {
        for language in StoreLanguage.allCases {
            let prefix = "store-\(language.rawValue)-"
            launch(["-example-price", "95", "-example-fees"], language: language)
            XCTAssertTrue(app.staticTexts["home.net"].waitForExistence(timeout: 5))
            shot(prefix + "01-calculator")
            tap("home.feeDetails", scroll: true)
            XCTAssertTrue(app.textFields["fee.buyer"].waitForExistence(timeout: 5))
            shot(prefix + "02-fees")
            app.terminate()

            launch(["-example-price", "12", "-example-fees", "-example-list"], language: language)
            XCTAssertTrue(app.staticTexts["home.hourly"].waitForExistence(timeout: 5))
            shot(prefix + "03-hourly")
            tap("home.list")
            XCTAssertTrue(app.descendants(matching: .any)["session.summary"].firstMatch.waitForExistence(timeout: 5))
            shot(prefix + "04-list")
            tap("session.share")
            XCTAssertTrue(app.descendants(matching: .any)["share.card"].firstMatch.waitForExistence(timeout: 5))
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
                                                     object: button("share.image"))
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
            shot(prefix + "05-share")
            app.terminate()
        }
    }

    func testPaidPaywallScreenshot() {
        launch(["-paid-mode", "-paywall"])
        XCTAssertTrue(app.staticTexts["paywall.title"].waitForExistence(timeout: 8))
        XCTAssertTrue(button("paywall.restore").exists)
        shot("paid-01-paywall")
    }
}
