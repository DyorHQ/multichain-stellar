// The Stellar section's app-side foundations (docs/DESIGN-stellar-parity.md §3.8, §3.9, §3.10, §4.6, §12.2): the review's
// fee words, checked addresses, the media pipeline's sources, the saved figures and the build's pins and media base.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import XCTest

@MainActor
final class StellarFoundationsTests: XCTestCase {
    // MARK: - The review's Max network fee (§4.6)

    /// The API's plan fixture's built step: an Enable USDC transaction declaring 0.001 XLM, from GCLJ….
    private static let trustXDR = "AAAAAgAAAACWkx+5IqHDdKtQ/Z773xUBaGRNzFg8rllQIi8Zjpt54AAAJxAAToEGAAAAAQAAAAEAAAAAas9OLAAAAABqz1CEAAAAAAAAAAEAAAAAAAAABgAAAAFVU0RDAAAAAEI+fQXy7K+/7BkrIVo/G+lq7bjY5wJUq+NBPgIH3layf/////////8AAAAAAAAAAA=="

    private func step(_ id: String, kind: String, built: Bool, intentKind: String = "trust") -> [String: Any] {
        var step: [String: Any] = ["id": id, "label": "Step \(id)", "status": built ? "built" : "pending", "stepKind": kind,
                                   "maxFee": built ? "10000" : "500000", "feePayer": "user", "reserveDelta": 0]
        if built {
            step["xdr"] = Self.trustXDR
            step["intent"] = ["kind": intentKind, "summary": "Enable USDC", "spend": [String: String](), "ops": ["changeTrust"],
                              "trust": ["USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"], "display": ["asset": "USDC"]]
        }
        return step
    }

    private func fees(_ steps: [[String: Any]], pinned: PinnedContracts = .testnet) throws -> PlanFees {
        let json: [String: Any] = ["planId": "p1", "kind": "swap", "expiresAt": "2026-10-14T09:56:00.000Z", "steps": steps]
        let plan = try JSONDecoder().decode(PlanView.self, from: JSONSerialization.data(withJSONObject: json))
        return try PlanFees(plan: plan, pinned: pinned)
    }

    func testOneBuiltStepReadsUpToItsFee() throws {
        let summary = StellarFeeSummary(try fees([step("s1", kind: "trust", built: true)]))
        XCTAssertEqual(StellarFormat.feeSummary(summary), "Up to 0.001 XLM")
    }

    func testStepsNotBuiltYetAreCountedAfterTheFee() throws {
        let summary = StellarFeeSummary(try fees([step("s1", kind: "trust", built: true), step("s2", kind: "swap_soroswap", built: false),
                                                  step("s3", kind: "swap_soroswap", built: false)]))
        XCTAssertEqual(StellarFormat.feeSummary(summary), "Up to 0.001 XLM + 2 more steps")
    }

    func testAPlanWithNothingBuiltIsPricedAsEachStepIsSigned() throws {
        let summary = StellarFeeSummary(try fees([step("s1", kind: "swap_soroswap", built: false)]))
        XCTAssertEqual(StellarFormat.feeSummary(summary), "Priced as each step is signed")
    }

    func testDyorHQPaysOnlyWhatThePhoneChecked() throws {
        // The account's setup, sent from the pinned sponsor: checked on the phone, so the sponsored value.
        let source = try TransactionEnvelope(base64: Self.trustXDR).transaction.source
        let sponsored = PinnedContracts(network: .testnet, sponsor: source, launchTokenWasmHash: "", roles: [:])
        let summary = StellarFeeSummary(try fees([step("s1", kind: "trust", built: true, intentKind: "activate")], pinned: sponsored))
        XCTAssertEqual(summary.value, .paidByDyorHQ)
        XCTAssertEqual(StellarFormat.feeSummary(summary), StellarFormat.sponsoredFee)
        XCTAssertTrue(StellarFormat.sponsoredFee.hasSuffix("by DyorHQ"), StellarFormat.sponsoredFee)
        XCTAssertEqual(summary.sponsorReason, .setup)
        // The same transaction from anyone but the pinned sponsor is the user's to pay, whatever the server says.
        let mine = StellarFeeSummary(try fees([step("s1", kind: "trust", built: true, intentKind: "activate")]))
        XCTAssertEqual(StellarFormat.feeSummary(mine), "Up to 0.001 XLM")
        XCTAssertNil(mine.sponsorReason)
    }

    func testAmountsAndFeesAreWrittenAsTheAppWritesThem() {
        XCTAssertEqual(StellarFormat.xlm(stroops: 154_000), "0.0154 XLM")
        XCTAssertEqual(StellarFormat.xlm(stroops: 30_000_000), "3 XLM")
        XCTAssertEqual(StellarFormat.units(12_505_000_000), "1,250.5")
        XCTAssertEqual(StellarFormat.amount(125_000_000, code: "USDC"), "12.5 USDC")
        // A field is written exactly, with no grouping, so it reads back as it was written.
        XCTAssertEqual(StellarFormat.plain(units: 12_505_000_000), "1250.5")
        XCTAssertEqual(StellarFormat.plain(units: 1), "0.0000001")
        XCTAssertEqual(StellarFormat.units("not a number"), "—")
        XCTAssertNotNil(StellarFormat.date("2026-10-14T09:41:00.000Z"))
        XCTAssertNotNil(StellarFormat.date("2026-10-14T09:41:00Z"))
    }

    // MARK: - Checked addresses, the only pasteboard source (§3.10 rule 1)

    private let account = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH"
    private let contract = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"

    func testAnAddressIsTakenOnlyWithItsChecksum() throws {
        let checked = try XCTUnwrap(StellarAccountID(account))
        XCTAssertEqual(checked.kind, .account)
        XCTAssertEqual(checked.checksummed, account)
        XCTAssertEqual(checked.short, "GCLJ…BNYH")
        XCTAssertEqual(StellarAccountID("  \(account)\n")?.checksummed, account, "blanks around it are trimmed")
        XCTAssertEqual(StellarAccountID(account.lowercased())?.checksummed, account, "written back in its canonical form")
        XCTAssertEqual(StellarAccountID(contract)?.kind, .contract)

        // One character changed: the checksum fails.
        var typo = Array(account)
        typo[10] = typo[10] == "A" ? "B" : "A"
        XCTAssertNil(StellarAccountID(String(typo)))
        XCTAssertNil(StellarAccountID(String(account.dropLast())))
        XCTAssertNil(StellarAccountID(""))
        XCTAssertNil(StellarAccountID("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"))
        // A secret key is never an address, so it can never be copied.
        let secret = try StellarSigner(seed: [UInt8](repeating: 5, count: 32)).secret
        XCTAssertNil(StellarAccountID(secret))
    }

    func testAnAddressOpensOnStellarExpertForThePinnedNetwork() throws {
        XCTAssertEqual(StellarAccountID(account)?.explorerURL(network: .testnet)?.absoluteString,
                       "https://stellar.expert/explorer/testnet/account/\(account)")
        XCTAssertEqual(StellarAccountID(contract)?.explorerURL(network: .testnet)?.absoluteString,
                       "https://stellar.expert/explorer/testnet/contract/\(contract)")
    }

    // MARK: - Images (§3.8)

    private let releaseBase = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/lite-media/")!
    private let releaseRender = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/render/image/public/lite-media/")!
    private let debugBase = URL(string: "http://127.0.0.1:8000/lite/v1/local-media/lite-media/")!

    private func upload(_ base: URL, ext: String = "jpg") -> String {
        "\(base.absoluteString)uploads/\(account)/0f8fad5b-d9cb-469f-a165-70867728950e.\(ext)"
    }

    func testReleaseLoadsTheRenderAtTheViewsBucketThenTheOriginal() {
        let uri = upload(releaseBase)
        let row = StellarImages.sources(uri, pointSize: 34, mediaBase: releaseBase, renderBase: releaseRender).map(\.url.absoluteString)
        XCTAssertEqual(row, [releaseRender.absoluteString + "uploads/\(account)/0f8fad5b-d9cb-469f-a165-70867728950e.jpg?width=96&resize=contain&quality=70", uri])
        // A page header (1200 px) is above the renderer's 768: the original alone. So is a gif, at any size.
        XCTAssertEqual(StellarImages.sources(uri, pointSize: 400, mediaBase: releaseBase, renderBase: releaseRender).map(\.url.absoluteString), [uri])
        let gif = upload(releaseBase, ext: "gif")
        XCTAssertEqual(StellarImages.sources(gif, pointSize: 34, mediaBase: releaseBase, renderBase: releaseRender).map(\.url.absoluteString), [gif])
    }

    func testDebugLoadsTheLocalOriginalsOnly() {
        let uri = upload(debugBase)
        XCTAssertEqual(StellarImages.sources(uri, pointSize: 34, mediaBase: debugBase, renderBase: nil).map(\.url.absoluteString), [uri])
        // Plain http only on the loopback: the same path on another host is refused.
        let elsewhere = uri.replacingOccurrences(of: "127.0.0.1", with: "example.com")
        XCTAssertEqual(StellarImages.sources(elsewhere, pointSize: 34, mediaBase: debugBase, renderBase: nil), [])
    }

    func testAnythingButDyorHQsOwnUploadsShowsLetters() {
        let uploads = upload(releaseBase)
        for uri in [nil, "", "https://evil.example/uploads/x.jpg", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
                    uploads + "?width=10", uploads.replacingOccurrences(of: "/uploads/", with: "/other/"),
                    uploads.replacingOccurrences(of: ".jpg", with: ".svg"), upload(releaseBase, ext: "mp4")] {
            XCTAssertEqual(StellarImages.sources(uri, pointSize: 34, mediaBase: releaseBase, renderBase: releaseRender), [], uri ?? "nil")
        }
        XCTAssertEqual(StellarImages.video(upload(releaseBase, ext: "mp4"), mediaBase: releaseBase)?.absoluteString, upload(releaseBase, ext: "mp4"))
        XCTAssertNil(StellarImages.video(uploads, mediaBase: releaseBase))
    }

    func testThisBuildPinsItsMediaBaseAndLocalNetworkingInDebugOnly() throws {
        // The internal Debug build (this test's host): the local stack's stand-in, originals only, and plain http to it.
        XCTAssertEqual(LiteGate.mediaBase, debugBase)
        XCTAssertNil(LiteGate.renderBase)
        let transport = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertEqual(transport["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertEqual(LiteGate.environment.mediaBase, debugBase)
    }

    // MARK: - Pins (§6.16)

    func testReleaseIgnoresLitePinnedAndDebugSelectsQAPinsOnlyWhenTheyExist() {
        for setting in [nil, "", "testnet", "testnet-qa", "mainnet"] {
            XCTAssertEqual(LiteGate.pins(for: setting, debug: false), .testnet, "Release: \(setting ?? "nil")")
        }
        XCTAssertEqual(LiteGate.pins(for: nil, debug: true), .testnet)
        XCTAssertEqual(LiteGate.pins(for: "testnet", debug: true), .testnet)
        XCTAssertEqual(LiteGate.pins(for: "mainnet", debug: true), .testnet, "no mainnet pins yet: never one the build doesn't have")
        #if STELLAR_QA_PINS
        XCTAssertEqual(LiteGate.pins(for: "testnet-qa", debug: true), .testnetQA)
        #else
        XCTAssertEqual(LiteGate.pins(for: "testnet-qa", debug: true), .testnet, "without testnet-qa pins, testnet's")
        #endif
    }

    // MARK: - Saved figures (§3.9)

    private struct Figures: Codable, Equatable, Sendable {
        let total: Int
    }

    private let owner = Address(data: Data(repeating: 1, count: 20))!
    private let other = Address(data: Data(repeating: 2, count: 20))!

    private func temporarySaved() -> StellarSaved {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stellar-saved-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return StellarSaved(screens: SavedScreens(directory: folder, build: "test"))
    }

    /// Waits until every save asked for so far is written: saves are written in order, so a later one that lands says
    /// the earlier ones were dealt with.
    private func settle(_ saved: StellarSaved) async throws {
        let marker = Address(data: Data(repeating: 9, count: 20))!
        let stamp = Int.random(in: 1...Int.max)
        saved.save(Figures(total: stamp), .myLaunchpad, owner: marker, savedAt: Date(), epoch: saved.epoch(for: marker))
        for _ in 0..<200 {
            if saved.load(Figures.self, .myLaunchpad, owner: marker)?.value.total == stamp { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the saves were never written")
    }

    func testTheFoldersArePerNetworkAndDeployment() {
        let name = StellarSaved.folderName(pinned: .testnet)
        XCTAssertTrue(name.hasPrefix("saved-screens-stellar-testnet-"), name)
        XCTAssertNotNil(name.split(separator: "-").last.flatMap { $0.count == 8 ? UInt32($0, radix: 16) : nil }, name)
        // A redeploy's contracts: another folder, so the old deployment's figures never show.
        let redeployed = PinnedContracts(network: .testnet, sponsor: PinnedContracts.testnet.sponsor, launchTokenWasmHash: "",
                                         roles: ["launchpad": [contract], "moments": PinnedContracts.testnet.contracts("moments")])
        XCTAssertNotEqual(StellarSaved.folderName(pinned: redeployed), name)
        XCTAssertEqual(StellarSaved.folderName(pinned: .testnet), name, "the same pins, the same folder")
    }

    func testForgettingAnAccountErasesItsFiguresAndNoOneElses() async throws {
        let saved = temporarySaved()
        saved.save(Figures(total: 5), .home, owner: owner, savedAt: Date(), epoch: saved.epoch(for: owner))
        saved.save(Figures(total: 7), .home, owner: other, savedAt: Date(), epoch: saved.epoch(for: other))
        try await settle(saved)
        XCTAssertEqual(saved.load(Figures.self, .home, owner: owner)?.value, Figures(total: 5))

        saved.forget(owner)
        XCTAssertNil(saved.load(Figures.self, .home, owner: owner))
        XCTAssertEqual(saved.load(Figures.self, .home, owner: other)?.value, Figures(total: 7))

        // A save asked for just before the forget never lands after it.
        saved.save(Figures(total: 6), .portfolio, owner: owner, savedAt: Date(), epoch: saved.epoch(for: owner))
        saved.forget(owner)
        try await settle(saved)
        XCTAssertNil(saved.load(Figures.self, .portfolio, owner: owner))
    }

    func testAReadThatBeganBeforeAForgetSavesNothing() async throws {
        let saved = temporarySaved()
        let began = saved.epoch(for: owner)
        saved.forget(owner) // Sign out of Stellar while the read was under way
        saved.save(Figures(total: 9), .home, owner: owner, savedAt: Date(), epoch: began)
        try await settle(saved)
        XCTAssertNil(saved.load(Figures.self, .home, owner: owner))

        // A read that begins after it is saved as any other.
        saved.save(Figures(total: 10), .home, owner: owner, savedAt: Date(), epoch: saved.epoch(for: owner))
        try await settle(saved)
        XCTAssertEqual(saved.load(Figures.self, .home, owner: owner)?.value, Figures(total: 10))

        // An erase of the device's figures guards the same way.
        let beforeErase = saved.epoch(for: owner)
        saved.screens.erase()
        saved.save(Figures(total: 11), .home, owner: owner, savedAt: Date(), epoch: beforeErase)
        try await settle(saved)
        XCTAssertNil(saved.load(Figures.self, .home, owner: owner))
    }

    func testSignOutAndEraseForgetTheAccountsStellarFigures() async throws {
        // `DyorHQLiteKeys.forget` (sign-out, erase this device) on the build's own saved figures.
        let account = Address(data: Data((0..<20).map { _ in UInt8.random(in: 0...255) }))!
        let saved = StellarSaved.shared
        saved.save(Figures(total: 3), .home, owner: account, savedAt: Date(), epoch: saved.epoch(for: account))
        try await settle(saved)
        XCTAssertEqual(saved.load(Figures.self, .home, owner: account)?.value, Figures(total: 3))
        DyorHQLiteKeys.forget(evm: account)
        XCTAssertNil(saved.load(Figures.self, .home, owner: account))
    }

    // MARK: - Text tables (§10)

    func testLiteTextIsInTheLiteAndStellarTables() {
        XCTAssertTrue(LiteText.isLiteTable("Lite"))
        XCTAssertTrue(LiteText.isLiteTable("StellarCommon"))
        XCTAssertTrue(LiteText.isLiteTable("StellarReview"))
        XCTAssertFalse(LiteText.isLiteTable("Stellar"))
        XCTAssertFalse(LiteText.isLiteTable("Localizable"))
        XCTAssertFalse(LiteText.isLiteTable(nil))
    }
}
