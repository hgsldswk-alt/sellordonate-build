import XCTest

final class StateTests: XCTestCase {
    func testAtomicSnapshotAndDuplicateDraft() throws {
        var state = LocalState(currency: .CNY)
        state.draft.price = "95"
        let captured = state.draft.id
        XCTAssertTrue(state.add(id: captured, to: .sell))
        XCTAssertFalse(state.add(id: captured, to: .donate))
        XCTAssertEqual(state.current.items.count, 1)
        XCTAssertEqual(state.draft.price, "")
        XCTAssertEqual(state.current.items[0].input.price, 95)
        XCTAssertEqual(try StateArchive.decode(StateArchive.encode(state)), state)

        XCTAssertEqual(try StateArchive.decode(JSONEncoder().encode(state)), state)
        let future = try JSONEncoder().encode(StateArchive.Envelope(version: 2, state: state))
        XCTAssertThrowsError(try StateArchive.decode(future))
    }

    func testLegacyArchiveRetainsCurrencySourceAndRate() throws {
        var legacy = LocalState(currency: .CNY)
        legacy.draft.preset = .standard(.xianyu)
        legacy.draft.price = "95"
        var savedDraft = CalculationDraft(currency: .USD)
        savedDraft.price = "42"
        var bare = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        bare["parked"] = ["USD": try JSONSerialization.jsonObject(with: JSONEncoder().encode(savedDraft))]
        bare.removeValue(forKey: "review")
        bare.removeValue(forKey: "unlockedMilestones")
        let migrated = try StateArchive.decode(JSONSerialization.data(withJSONObject: bare))
        XCTAssertEqual(migrated.draft.currency, .CNY)
        XCTAssertEqual(migrated.draft.preset?.source, legacy.draft.preset?.source)
        XCTAssertEqual(migrated.draft.preset?.checkedOn, legacy.draft.preset?.checkedOn)
        XCTAssertEqual(migrated.draft.preset?.rate, legacy.draft.preset?.rate)
        XCTAssertEqual(migrated.parked["USD"], [savedDraft])
    }

    func testExpiredReusePreservesHistory() {
        var state = LocalState(currency: .CNY)
        state.draft.price = "95"
        state.draft.preset = .standard(.xianyu)
        XCTAssertTrue(state.add(id: state.draft.id, to: .sell))
        let snapshot = state.current.items[0]
        XCTAssertTrue(state.hasReusablePresets)
        state.reuseFeeValues()
        XCTAssertFalse(state.hasReusablePresets)
        XCTAssertEqual(state.draft.amount(state.draft.fee), snapshot.estimate.fee)
        XCTAssertEqual(state.current.items[0], snapshot)
    }

    func testCurrencySwitchKeepsMultipleDraftsAndRatesSeparate() {
        var state = LocalState(currency: .CNY)
        state.draft.price = "95"
        state.draft.shipping = "8"
        state.draft.preset = .standard(.xianyu)
        state.changeCurrency(.USD, empty: true)
        XCTAssertEqual(state.draft.price, "")
        XCTAssertEqual(state.draft.threshold, "15")
        state.draft.price = "20"
        state.changeCurrency(.CNY, empty: true)
        XCTAssertEqual(state.draft.price, "")
        XCTAssertEqual(state.draft.shipping, "8")
        state.draft.price = "11"
        state.changeCurrency(.USD, empty: true)
        state.changeCurrency(.CNY, empty: true)
        XCTAssertTrue(state.restoreParkedDraft())
        XCTAssertEqual(state.draft.price, "11")
        XCTAssertTrue(state.restoreParkedDraft())
        XCTAssertEqual(state.draft.price, "95")
        XCTAssertEqual(state.draft.preset?.platform, .xianyu)
    }

    func testCompletionCorrectionDonationAndSeparateCurrencies() throws {
        var state = LocalState(currency: .USD)
        state.draft.price = "40"
        XCTAssertTrue(state.add(id: state.draft.id, to: .sell))
        let id = state.current.items[0].id
        XCTAssertEqual(state.current.summary.completed, 0)
        XCTAssertTrue(state.current.items[0].update(.sold, actual: 35))
        state.recordCompletion(id)
        XCTAssertTrue(state.current.items[0].update(.sold, actual: -2))
        state.recordCompletion(id)
        XCTAssertEqual(state.current.summary.income[.USD], -2)
        XCTAssertEqual(state.completedIDs.count, 1)

        state.changeCurrency(.CNY)
        state.draft.price = "80"
        XCTAssertTrue(state.add(id: state.draft.id, to: .sell))
        XCTAssertTrue(state.current.items[0].update(.sold, actual: 72))
        XCTAssertEqual(state.current.summary.income, [.USD: -2, .CNY: 72])
        XCTAssertTrue(state.current.items[0].update(.donate, invested: 5))
        XCTAssertEqual(state.current.summary.income, [.USD: -2])
        XCTAssertTrue(state.current.items[0].update(.donated, invested: 5))
        XCTAssertEqual(state.current.summary.missingDonationTime, 1)
        XCTAssertTrue(state.current.items[0].update(.donated, invested: 5, donated: 7))
        XCTAssertEqual(state.current.summary.savedMinutes, 13)
        XCTAssertEqual(SessionSummary.allocateTrip(10, items: 3), [4, 3, 3])
        XCTAssertEqual(SessionSummary.allocateTrip(0, items: 3), [0, 0, 0])
    }

    func testReviewAsksOnThirdDistinctDay() {
        var state = LocalState(currency: .USD)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        for index in 0..<3 {
            state.draft.price = "12"
            let id = state.draft.id
            XCTAssertTrue(state.add(id: id, to: .donate))
            XCTAssertTrue(state.current.items[0].update(.donated, donated: 5,
                now: now.addingTimeInterval(Double(index - 2) * 86400), calendar: calendar))
            state.recordCompletion(id)
            if index == 1 { XCTAssertFalse(state.review.canRequest(version: "1", now: now, items: state.allItems)) }
        }
        XCTAssertTrue(state.review.canRequest(version: "1", now: now, items: state.allItems))
    }

    func testMilestoneAndReviewThrottle() {
        var state = LocalState(currency: .USD)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        for index in 0..<100 {
            state.draft.price = "12"
            let id = state.draft.id
            XCTAssertTrue(state.add(id: id, to: .donate))
            XCTAssertTrue(state.current.items[0].update(.donated, donated: 5,
                now: now.addingTimeInterval(index == 0 ? -86400 : 0), calendar: calendar))
            state.recordCompletion(id)
            state.recordCompletion(id)
        }
        XCTAssertEqual(state.unlockedMilestones, [10, 50, 100])
        XCTAssertEqual(state.completedIDs.count, 100)
        XCTAssertTrue(state.review.canRequest(version: "1", now: now, items: state.allItems))
        let later = now.addingTimeInterval(120 * 86400)
        state.review = ReviewHistory(version: "1", date: now)
        XCTAssertFalse(state.review.canRequest(version: "1", now: later, items: state.allItems))
        XCTAssertFalse(state.review.canRequest(version: "2", now: later.addingTimeInterval(-1), items: state.allItems))
        XCTAssertTrue(state.review.canRequest(version: "2", now: later, items: state.allItems))
        let original = state.current.id
        state.startSession(now: later)
        XCTAssertEqual(state.past.first?.id, original)
        XCTAssertEqual(state.past.first?.summary.completed, 100)
        XCTAssertTrue(state.current.items.isEmpty)
    }

    func testResultsShareRequiresCompletedItemsInThatList() {
        var state = LocalState(currency: .USD)
        XCTAssertFalse(state.current.hasCompletedItems)
        state.draft.price = "50"
        XCTAssertTrue(state.add(id: state.draft.id, to: .sell))
        XCTAssertFalse(state.current.hasCompletedItems)
        XCTAssertTrue(state.current.items[0].update(.sold, actual: 0))
        XCTAssertTrue(state.current.hasCompletedItems)
        XCTAssertTrue(state.current.items[0].update(.donate))
        XCTAssertFalse(state.current.hasCompletedItems)
        XCTAssertTrue(state.current.items[0].update(.donated))
        XCTAssertTrue(state.current.hasCompletedItems)
        state.startSession()
        XCTAssertEqual(state.past.first?.hasCompletedItems, true)
        XCTAssertFalse(state.current.hasCompletedItems)
    }

    func testDiscardedCountsSeparatelyFromSalesAndDonations() {
        var state = LocalState(currency: .USD)
        for _ in 0..<4 {
            state.draft.price = "50"
            XCTAssertTrue(state.add(id: state.draft.id, to: .sell))
        }
        XCTAssertTrue(state.current.items[0].update(.sold, actual: 35))
        XCTAssertTrue(state.current.items[1].update(.donated, invested: 5, donated: 7))
        XCTAssertTrue(state.current.items[2].update(.discarded))

        let summary = state.current.summary
        XCTAssertEqual(summary.sold, 1)
        XCTAssertEqual(summary.donated, 1)
        XCTAssertEqual(summary.discarded, 1)
        XCTAssertEqual(summary.completed, 3)
        XCTAssertEqual(summary.income, [.USD: 35])
        XCTAssertEqual(summary.savedMinutes, 13)
        XCTAssertEqual(summary.missingDonationTime, 0)

        XCTAssertTrue(state.current.items[0].update(.discarded))
        XCTAssertTrue(state.current.items[1].update(.discarded))
        XCTAssertNil(state.current.items[0].actualNet)
        XCTAssertNil(state.current.items[1].donationMinutes)
        XCTAssertTrue(state.current.summary.income.isEmpty)
        XCTAssertEqual(state.current.summary.savedMinutes, 0)
        XCTAssertEqual(state.current.summary.discarded, 3)
        XCTAssertTrue(state.current.hasCompletedItems)

        XCTAssertTrue(state.current.items[2].update(.donate))
        XCTAssertNil(state.current.items[2].completedAt)
        XCTAssertEqual(state.current.summary.discarded, 2)
    }

    func testDiscardedSurvivesArchivingAndExportsItsDestination() throws {
        var state = LocalState(currency: .USD)
        state.draft.price = "50"
        XCTAssertTrue(state.add(id: state.draft.id, to: .sell))
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertTrue(state.current.items[0].update(.sold, actual: 35, now: now.addingTimeInterval(-86400)))
        XCTAssertTrue(state.current.items[0].update(.discarded, now: now))
        state.startSession(now: now)

        let reloaded = try StateArchive.decode(StateArchive.encode(state))
        let past = try XCTUnwrap(reloaded.past.first)
        let item = try XCTUnwrap(past.items.first)
        XCTAssertEqual(item.status, .discarded)
        XCTAssertEqual(item.completedAt, now)
        XCTAssertEqual(past.summary.discarded, 1)
        XCTAssertEqual(reloaded.current.summary.discarded, 0)
        XCTAssertEqual(SessionSummary(items: reloaded.allItems).discarded, 1)
        let status = L.t("status.discarded")
        XCTAssertNotEqual(status, "status.discarded")
        XCTAssertTrue(CSVExport.contents(past).contains(",\"\(status)\",USD,50,0,0,0,50,25,,0,,,"))
    }

    func testCSVQuotingAndActualAmounts() {
        var state = LocalState(currency: .USD)
        state.draft.price = "50"
        XCTAssertTrue(state.add(id: state.draft.id, to: .sell))
        state.current.items[0].name = "  =SUM(1,2)\"\nDemo"
        XCTAssertTrue(state.current.items[0].update(.sold, actual: -3))
        let csv = CSVExport.contents(state.current)
        XCTAssertTrue(csv.contains("\"'  =SUM(1,2)\"\"\nDemo\""))
        XCTAssertTrue(csv.contains(",USD,50,0,0,0,50,25,-3,"))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        XCTAssertNotEqual(L.t("session.current"), "session.current")
    }

    func testCSVIncludesOnlyTheSelectedHistoryList() throws {
        var state = LocalState(currency: .USD)
        for name in ["First list", "Second list", "Current list"] {
            state.draft.price = "50"
            XCTAssertTrue(state.add(id: state.draft.id, to: .sell))
            state.current.items[0].name = name
            if name != "Current list" { state.startSession() }
        }
        let past = try XCTUnwrap(state.past.last)
        let csv = CSVExport.contents(past)
        XCTAssertTrue(csv.contains("\"First list\""))
        XCTAssertFalse(csv.contains("Second list"))
        XCTAssertFalse(csv.contains("Current list"))
    }
}
