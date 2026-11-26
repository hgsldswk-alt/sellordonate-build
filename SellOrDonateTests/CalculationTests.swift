import XCTest

final class CalculationTests: XCTestCase {
    private func n(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    func testPlanExamplesAndThreshold() throws {
        var input = CalculationInput(currency: .CNY, price: 95, sellerShipping: 8,
                                     preset: .standard(.xianyu), minutes: 25, threshold: 60)
        var result = try XCTUnwrap(Calculator.calculate(input))
        XCTAssertEqual(result.fee, n("0.57"))
        XCTAssertEqual(result.net, n("86.43"))
        XCTAssertEqual(result.hourly, n("207.43"))
        XCTAssertEqual(result.recommendation, .sell)
        input.price = 12
        result = try XCTUnwrap(Calculator.calculate(input))
        XCTAssertEqual(result.fee, n("0.07"))
        XCTAssertEqual(result.net, n("3.93"))
        XCTAssertEqual(result.hourly, n("9.43"))
        XCTAssertEqual(result.recommendation, .donate)

        input = CalculationInput(currency: .USD, price: 15, minutes: 60, threshold: 15)
        XCTAssertEqual(Calculator.calculate(input)?.recommendation, .sell)
        input.minutes = 121
        input.price = n("30.24")
        result = try XCTUnwrap(Calculator.calculate(input))
        XCTAssertEqual(result.hourly, 15)
        XCTAssertEqual(result.recommendation, .donate)
        XCTAssertEqual(result.relation, .near)
    }

    func testZeroNegativeInvalidAndCrossCurrency() throws {
        var input = CalculationInput(currency: .USD, price: 0, minutes: 25, threshold: 0)
        XCTAssertEqual(Calculator.calculate(input)?.recommendation, .donate)
        input.sellerShipping = 8
        XCTAssertEqual(Calculator.calculate(input)?.net, -8)
        XCTAssertEqual(Calculator.calculate(input)?.hourly, n("-19.20"))
        input.minutes = 0
        XCTAssertNil(Calculator.calculate(input))
        input.minutes = 25
        input.preset = .standard(.xianyu)
        XCTAssertNil(Calculator.calculate(input))
        XCTAssertNil(CalculationDraft(currency: .USD).input)
    }

    func testPresetBoundariesAndExtraBase() throws {
        let ebay = FeePreset.standard(.ebay)
        XCTAssertEqual(ebay.fee(price: 10, buyerShipping: 0, extraBase: 0), n("1.66"))
        XCTAssertEqual(ebay.fee(price: n("10.01"), buyerShipping: 0, extraBase: 0), n("1.76"))
        XCTAssertEqual(ebay.fee(price: 7500, buyerShipping: 0, extraBase: 0), n("1020.40"))
        XCTAssertEqual(ebay.fee(price: 7600, buyerShipping: 0, extraBase: 0), n("1022.75"))
        let poshmark = FeePreset.standard(.poshmark)
        XCTAssertEqual(poshmark.fee(price: n("14.99"), buyerShipping: 8, extraBase: 1), n("2.95"))
        XCTAssertEqual(poshmark.fee(price: 15, buyerShipping: 8, extraBase: 1), 3)
        let vinted = FeePreset.standard(.vinted)
        XCTAssertEqual(vinted.fee(price: 1000, buyerShipping: 20, extraBase: 10), 0)
        let xianyu = FeePreset.standard(.xianyu)
        XCTAssertEqual(xianyu.fee(price: 9990, buyerShipping: 0, extraBase: 0), n("59.94"))
        XCTAssertEqual(xianyu.fee(price: 9990, buyerShipping: 10, extraBase: 0), 60)
        XCTAssertEqual(xianyu.fee(price: 10_000, buyerShipping: 10, extraBase: 0), 60)
        let input = CalculationInput(currency: .USD, price: 10, buyerShipping: 5, additionalFeeBase: 2,
                                     sellerShipping: 3, preset: ebay, minutes: 25, threshold: 15)
        let result = try XCTUnwrap(Calculator.calculate(input))
        XCTAssertEqual(result.fee, n("2.71"))
        XCTAssertEqual(result.net, n("9.29"))
        XCTAssertTrue(Platform.allCases.allSatisfy { FeePreset.standard($0).isValid })
    }

    func testLocalizedInputAndCurrencyPrecision() {
        let maximum = Currency.EUR.maximum
        XCTAssertEqual(NumberInput.parse("１２，３４", scale: 2, maximum: maximum,
                                         locale: Locale(identifier: "fr_FR")), n("12.34"))
        XCTAssertEqual(NumberInput.parse("−8,50", scale: 2, maximum: maximum, signed: true), n("-8.5"))
        XCTAssertEqual(NumberInput.parse("999999.99", scale: 2, maximum: maximum), maximum)
        for invalid in ["9999999", "12345678901234567", "1,002", "1e2", "1.2.3", " ", "-1", "Ⅳ", "."] {
            XCTAssertNil(NumberInput.parse(invalid, scale: 2, maximum: maximum), invalid)
        }
        XCTAssertNil(NumberInput.parse("12.50", scale: Currency.JPY.scale, maximum: Currency.JPY.maximum))
    }
}

