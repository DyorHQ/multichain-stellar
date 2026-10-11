import Foundation
@testable import LiteClient
import StellarCore
import XCTest

final class ContractInspectorTests: XCTestCase {
    func testInstanceKeyMatchesStellarSDK() throws {
        // xdr.LedgerKey.contractData({ contract, ledgerKeyContractInstance, persistent }) from stellar-sdk 16.
        XCTAssertEqual(
            try ContractInspector.instanceKey("CC4EJ5O6OIK66NET7LLUWKG7XHFVSF255GJCVBKXRQA2LAVPNWK4SMMS"),
            "AAAABgAAAAG4RPXechXvNJP610so37nLWRdd6ZIqhVeMAaWCr22VyQAAABQAAAAB"
        )
    }
}

/// Runs only when pointed at a Lite API on testnet:
///   LITE_API=http://127.0.0.1:8000/lite LITE_INVITE=DYOR-XXXXX-XXXXX swift test --filter LiteJourney
/// It is the phone's own code path end to end: derive a key, sign in with an invite, activate, then a swap through
/// PlanRunner (verify against pinned contracts + the user's limits → sign → submit → confirm), a refusal when the
/// plan would spend more than confirmed, and SEP-10 + SEP-24 against testanchor.stellar.org.
final class LiteJourneyTests: XCTestCase {
    func testLiteJourneyOnTestnet() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["LITE_API"].flatMap(URL.init(string:)), let invite = env["LITE_INVITE"] else {
            throw XCTSkip("LITE_API and LITE_INVITE not set")
        }
        let phrase = try XCTUnwrap(Mnemonic.phrase(entropy: (0..<32).map { _ in UInt8.random(in: 0...255) }))
        let signer = try StellarDerivation.sep5(mnemonic: phrase)
        let api = LiteAPI(baseURL: base)
        let config = try await api.config()
        XCTAssertEqual(config.passphrase, StellarNetwork.testnet.passphrase)
        let pinned = PinnedContracts.testnet
        XCTAssertEqual(config.sponsor, pinned.sponsor, "regenerate PinnedContracts+Testnet.swift for this API's sponsor")

        // Sign in: refused without an invite, accepted with one.
        do {
            _ = try await api.signIn(signer: signer)
            XCTFail("signed in without an invite")
        } catch let e as LiteAPIError {
            XCTAssertEqual(e.code, "not_invited")
        }
        _ = try await api.signIn(signer: signer, inviteCode: invite)

        let runner = PlanRunner(api: api, user: signer.address, pinned: pinned, inspector: ContractInspector(rpcURL: URL(string: config.rpcUrl)!))
        let key: @Sendable () async throws -> StellarSigner = { signer }

        // Activate (Friendbot on testnet) and enable USDC (sponsored reserve, nothing spent).
        let activation = try await api.activate()
        if let plan = activation.plan { try await runner.run(plan, limits: [:], signer: key) }
        var account = try await api.account()
        XCTAssertTrue(account.exists)
        XCTAssertTrue(account.balances.first { $0.asset == "USDC" }?.enabled ?? false)

        // A swap the user confirmed at 10 XLM.
        let xlm = try XCTUnwrap(config.asset("XLM"))
        let usdc = try XCTUnwrap(config.asset("USDC"))
        let ten = Int64(100_000_000)
        let quote = try await api.quoteSwap(sell: "XLM", buy: "USDC", amount: ten, slippageBps: 300)
        let plan = try await api.buildSwap(quoteId: quote.quoteId)

        // The same plan with a 9 XLM limit is refused before anything is signed.
        do {
            try await runner.run(plan, limits: [xlm.contract: ten - 10_000_000], signer: key)
            XCTFail("over-limit plan was signed")
        } catch let f as PlanRunner.Failure {
            XCTAssertEqual(f, .overLimit(asset: xlm.contract))
        }
        let results = try await runner.run(plan, limits: [xlm.contract: ten], signer: key)
        XCTAssertEqual(results.last?.status, "success")
        account = try await api.account()
        XCTAssertGreaterThan(account.balance("USDC"), 0)
        XCTAssertGreaterThan(account.balance(usdc.id), 0)

        // Cash in: SEP-10 with the account key, then a SEP-24 interactive deposit URL.
        let anchor = AnchorClient(domain: "testanchor.stellar.org", network: .testnet)
        let toml = try await anchor.toml()
        let jwt = try await anchor.authenticate(signer: signer, toml: toml)
        let flow = try await anchor.interactive(deposit: true, assetCode: "USDC", account: signer.address, jwt: jwt, toml: toml)
        XCTAssertTrue(flow.url.hasPrefix("https://"))
        let tx = try await anchor.transaction(id: flow.id, jwt: jwt, toml: toml)
        XCTAssertEqual(tx.kind, "deposit")
        try await api.trackCash(anchor: "testanchor.stellar.org", deposit: true, asset: "USDC", anchorTxId: flow.id, status: tx.status, amount: nil)
        let activity = try await api.activity()
        XCTAssertTrue(activity.contains { $0.type == "cash" })
    }
}
