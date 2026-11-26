import CoreImage
import XCTest

final class ShareAndEntitlementTests: XCTestCase {
    func testCodeWhitelistAndRoundTrip() throws {
        let preset = FeePreset.standard(.xianyu)
        let settings = ShareSettings(currency: .CNY, threshold: 60, minutes: 25, template: .init(preset))
        let code = try ShareCode.encode(settings)
        XCTAssertTrue(code.hasPrefix("SD1:"))
        XCTAssertFalse(code.contains("="))
        XCTAssertEqual(try ShareCode.decode(" \t" + code + "\r\n"), settings)
        XCTAssertThrowsError(try ShareCode.decode(String(code.dropLast())))
        XCTAssertThrowsError(try ShareCode.decode(" \n"))
        XCTAssertThrowsError(try ShareCode.decode("SD2:" + code.dropFirst(4)))
        XCTAssertThrowsError(try ShareCode.decode("SD1:" + String(repeating: "x", count: 3000)))
        XCTAssertThrowsError(try ShareCode.encode(ShareSettings(currency: .USD, threshold: 20, minutes: 0)))
        XCTAssertThrowsError(try ShareCode.encode(ShareSettings(currency: .USD, threshold: 10, minutes: 20,
                                                                template: .init(preset))))
        for payload in [
            #"{"version":2,"currency":"USD","threshold":15,"minutes":25}"#,
            #"{"version":1,"currency":"USD","threshold":-1,"minutes":25}"#,
            #"{"version":1,"currency":"USD","threshold":15,"minutes":25,"price":60}"#
        ] {
            let suffix = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
            XCTAssertThrowsError(try ShareCode.decode("SD1:" + suffix))
        }
    }

    func testQRCodeCanBeScanned() throws {
        XCTAssertEqual(QRCode.downloadLink(appStoreID: ""), QRCode.placeholder)
        XCTAssertEqual(QRCode.downloadLink(appStoreID: "12345"), "https://apps.apple.com/app/id12345")
        let image = try XCTUnwrap(QRCode.image(for: QRCode.placeholder))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let decoded = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertTrue(decoded.contains(QRCode.placeholder))
    }

    func testInitialPaidLaunchAndExactExpiry() {
        let first = Date(timeIntervalSince1970: 1_760_000_000)
        let paid = first.addingTimeInterval(40 * 86400)
        var access = Entitlement(firstOpen: first)
        XCTAssertFalse(Launch.isFree(arguments: ["-paid-mode"]))
        XCTAssertTrue(access.hasPro(at: paid, free: true))
        XCTAssertFalse(access.hasPro(at: paid, free: false))
        access.open(at: first, free: true)
        XCTAssertNil(access.proStartedAt)
        access.open(at: paid, free: false)
        XCTAssertEqual(access.trialStart, paid)
        let end = paid.addingTimeInterval(Entitlement.trialDuration)
        XCTAssertTrue(access.hasPro(at: end.addingTimeInterval(-1), free: false))
        XCTAssertFalse(access.hasPro(at: end, free: false))
        access.open(at: end, free: false)
        XCTAssertFalse(access.hasPro(at: first, free: false))
        access.purchasedPro = true
        XCTAssertTrue(access.hasPro(at: end, free: false))
        access.purchasedPro = false
        XCTAssertFalse(access.hasPro(at: end, free: false))
    }

    func testVerifiedTrialUsesEarlierDateOnRestoreAndReinstall() throws {
        let first = Date(timeIntervalSince1970: 1_760_000_000)
        let claim = first.addingTimeInterval(5 * 86400)
        var access = Entitlement(firstOpen: first, proStartedAt: first)
        access.applyTrialReceipt(originalDate: claim)
        XCTAssertEqual(access.trialStart, first)
        let reinstalled = try JSONDecoder().decode(Entitlement.self, from: JSONEncoder().encode(access))
        XCTAssertEqual(reinstalled.trialStart, first)
        let newDevice = claim.addingTimeInterval(10 * 86400)
        var restored = Entitlement(firstOpen: newDevice, proStartedAt: newDevice)
        restored.applyTrialReceipt(originalDate: claim)
        XCTAssertEqual(restored.trialStart, claim)
        XCTAssertEqual(restored.trialEnd, claim.addingTimeInterval(Entitlement.trialDuration))
    }
}
