import BigInt
import Foundation

/// Aurora Intents (NEAR Intents) Swap API — the cross-chain bridge behind the Home "Bridge" button. The app requests
/// a quote, sends the origin-chain deposit itself (same wallet, any EVM chain), reports the tx, then polls status.
/// Every call goes through DyorHQ's `aurora-proxy` Edge Function, which holds the Aurora API key server-side and
/// forwards only these four endpoints for a signed-in wallet — the key never ships in the app. The integrator fee is
/// configured on the key in Aurora Studio. Docs: https://docs.intents.aurora.dev/api-reference/swap-api-reference.
public struct AuroraIntents: Sendable {
    /// The proxy's base URL (…/functions/v1/aurora-proxy); endpoint paths are appended to it.
    public let base: URL
    /// Optional NEAR account to receive the integrator fee, sent as `appFees` on each quote. When nil the key's own
    /// Studio fee configuration applies instead.
    public let feeRecipient: String?
    public let feeBps: Int
    /// Headers that authenticate a call to the proxy as the signed-in wallet (throws when there is no session).
    private let authorize: @Sendable () async throws -> [String: String]
    private let session: URLSession

    public init(proxy: URL,
                feeRecipient: String? = nil,
                feeBps: Int = 10,
                authorize: @escaping @Sendable () async throws -> [String: String],
                session: URLSession = .shared) {
        self.base = proxy
        self.feeRecipient = feeRecipient
        self.feeBps = feeBps
        self.authorize = authorize
        self.session = session
    }

    public var isConfigured: Bool { true }

    // MARK: Endpoints

    /// Every supported token across every chain, each with its `blockchain`, `assetId`, `decimals` and (for ERC-20s)
    /// `contractAddress`. Public — any key value returns the global list.
    public func tokens() async throws -> [AuroraToken] {
        struct Wrap: Decodable { let tokens: [AuroraToken] }
        return try await get("tokens", as: Wrap.self).tokens
    }

    /// A quote for `amount` (smallest units of `originAsset`) into `destinationAsset`, delivered to `recipient` on the
    /// destination chain, refunded to `refundTo` on the origin chain. Returns the origin-chain deposit address to fund.
    public func quote(amount: String,
                      originAsset: String,
                      destinationAsset: String,
                      recipient: String,
                      refundTo: String,
                      slippageBps: Int) async throws -> AuroraQuote {
        let body = AuroraQuoteRequest(
            dry: false, swapType: "EXACT_INPUT", depositType: "ORIGIN_CHAIN",
            amount: amount, originAsset: originAsset, destinationAsset: destinationAsset,
            slippageTolerance: slippageBps, refundTo: refundTo, refundType: "ORIGIN_CHAIN",
            recipient: recipient, recipientType: "DESTINATION_CHAIN", referral: "dyorhq",
            appFees: feeRecipient.map { [AuroraAppFee(recipient: $0, fee: feeBps)] }
        )
        let response = try await post("quote", body: body, as: AuroraQuoteResponse.self)
        var quote = response.quote
        quote.request = response.quoteRequest
        return quote
    }

    /// Tells Aurora the deposit was sent, so it starts settling without waiting to observe the tx itself.
    @discardableResult
    public func submitDeposit(txHash: String, depositAddress: String, memo: String? = nil) async throws -> AuroraSwapState {
        try await post("deposit/submit", body: AuroraSubmitRequest(txHash: txHash, depositAddress: depositAddress, memo: memo), as: AuroraSwapState.self)
    }

    /// The current settlement status for a deposit address (from `PENDING_DEPOSIT` through `SUCCESS` / `REFUNDED`).
    public func status(depositAddress: String, depositMemo: String? = nil) async throws -> AuroraSwapState {
        var items = [URLQueryItem(name: "depositAddress", value: depositAddress)]
        if let depositMemo { items.append(URLQueryItem(name: "depositMemo", value: depositMemo)) }
        return try await get("status", query: items, as: AuroraSwapState.self)
    }

    // MARK: Transport

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        var req = URLRequest(url: url(path, query: query))
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await run(req)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B, as: T.Type) async throws -> T {
        var req = URLRequest(url: url(path))
        req.timeoutInterval = 20
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await run(req)
    }

    private func run<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        let headers: [String: String]
        do { headers = try await authorize() } catch { throw AuroraError.signInRequired }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuroraError.transport(L10n.tr("No response")) }
        guard (200..<300).contains(http.statusCode) else {
            // Aurora's own `message`, or the proxy's `error` (bridge not configured, sign-in required, bad route).
            let body = try? JSONDecoder().decode(AuroraErrorBody.self, from: data)
            if http.statusCode == 503 { throw AuroraError.notConfigured }
            if http.statusCode == 401 || http.statusCode == 403 { throw AuroraError.signInRequired }
            // not localized: Aurora's own message, shown as it sends it (`BridgeModel.humanize` reads it)
            throw AuroraError.api(status: http.statusCode, message: body?.message ?? body?.error ?? L10n.tr("Aurora request failed (\(String(http.statusCode)))."))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AuroraError.decoding(error.localizedDescription) }
    }
}

public enum AuroraError: LocalizedError {
    case notConfigured
    case signInRequired
    case api(status: Int, message: String)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return L10n.tr("The bridge is temporarily unavailable. Please try again shortly.")
        case .signInRequired: return L10n.tr("Connect your wallet to DyorHQ to use the bridge.")
        case .api(_, let message): return message
        case .transport(let m): return m
        case .decoding(let m): return L10n.tr("Couldn't read Aurora's response: \(m)")
        }
    }
}

private struct AuroraErrorBody: Decodable { let message: String?; let error: String? }

// MARK: - Models

/// A token Aurora can bridge. `assetId` is Aurora's canonical id (`nep245:v2_1.omni.hot.tg:<evmChainId>_<suffix>`);
/// `contractAddress` is the ERC-20 address on `blockchain`, absent for the chain's native asset. Encodable too, so an
/// in-flight bridge can persist its destination token.
public struct AuroraToken: Codable, Sendable, Hashable, Identifiable {
    public let assetId: String
    public let decimals: Int
    public let blockchain: String
    public let symbol: String
    public let contractAddress: String?
    public let price: Double?
    public var id: String { assetId }
    public var isNative: Bool { contractAddress == nil }
}

struct AuroraAppFee: Encodable, Sendable { let recipient: String; let fee: Int }

struct AuroraQuoteRequest: Encodable, Sendable {
    let dry: Bool
    let swapType: String
    let depositType: String
    let amount: String
    let originAsset: String
    let destinationAsset: String
    let slippageTolerance: Int
    let refundTo: String
    let refundType: String
    let recipient: String
    let recipientType: String
    let referral: String?
    let appFees: [AuroraAppFee]?
}

struct AuroraSubmitRequest: Encodable, Sendable {
    let txHash: String
    let depositAddress: String
    let memo: String?
}

struct AuroraQuoteResponse: Decodable, Sendable { let quote: AuroraQuote; let quoteRequest: AuroraQuoteEcho? }

/// The request as Aurora echoes it back with the quote (`quoteRequest`) — what the deposit address will actually
/// settle. The app checks it against what the user asked for before signing anything.
public struct AuroraQuoteEcho: Decodable, Sendable, Equatable {
    public let amount: String?
    public let originAsset: String?
    public let destinationAsset: String?
    public let recipient: String?
    public let refundTo: String?
    public let swapType: String?

    public init(amount: String?, originAsset: String?, destinationAsset: String?, recipient: String?, refundTo: String?, swapType: String?) {
        self.amount = amount
        self.originAsset = originAsset
        self.destinationAsset = destinationAsset
        self.recipient = recipient
        self.refundTo = refundTo
        self.swapType = swapType
    }

    /// Whether this quote settles exactly the request: the typed amount, EXACT_INPUT, the chosen assets, and the
    /// user's own address as both recipient and refund address.
    public func matches(amount: BigUInt, originAsset: String, destinationAsset: String, owner: Address) -> Bool {
        self.amount.flatMap { BigUInt($0) } == amount
            && swapType == "EXACT_INPUT"
            && self.originAsset == originAsset
            && self.destinationAsset == destinationAsset
            && recipient.flatMap { Address($0) } == owner
            && refundTo.flatMap { Address($0) } == owner
    }
}

/// The actionable part of a quote: where to send on the origin chain, and the amounts.
public struct AuroraQuote: Decodable, Sendable {
    public let depositAddress: String?
    public let depositMemo: String?
    public let amountIn: String
    public let amountInFormatted: String?
    public let amountInUsd: String?
    public let amountOut: String
    public let amountOutFormatted: String?
    public let amountOutUsd: String?
    public let minAmountOut: String?
    public let refundFee: String?
    public let withdrawFee: String?
    public let deadline: String?
    public let timeEstimate: Double?
    /// Aurora's echo of the request this quote answers (set by `AuroraIntents.quote`).
    public var request: AuroraQuoteEcho?
}

public enum AuroraSwapStatus: String, Decodable, Sendable {
    case knownDepositTx = "KNOWN_DEPOSIT_TX"
    case pendingDeposit = "PENDING_DEPOSIT"
    case incompleteDeposit = "INCOMPLETE_DEPOSIT"
    case processing = "PROCESSING"
    case success = "SUCCESS"
    case refunded = "REFUNDED"
    case failed = "FAILED"
}

public struct AuroraSwapState: Decodable, Sendable {
    public let status: AuroraSwapStatus
    public let updatedAt: String?
    public let swapDetails: AuroraSwapDetails?

    private enum CodingKeys: String, CodingKey { case status, updatedAt, swapDetails }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognized status (a new value, casing drift) must never throw and stall the poll — treat it as still
        // in progress and let the settlement poll (and the destination-balance check) resolve it.
        status = (try? c.decode(AuroraSwapStatus.self, forKey: .status)) ?? .processing
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        // `swapDetails` is secondary (formatted amount, refund reason). The poll only needs `status` to advance, so a
        // decode failure or schema drift in `swapDetails` must NEVER stall settlement tracking — swallow it to nil.
        swapDetails = try? c.decodeIfPresent(AuroraSwapDetails.self, forKey: .swapDetails)
    }
}

/// A settlement transaction reference from Aurora (`{hash, explorerUrl}`).
public struct AuroraTxRef: Decodable, Sendable, Hashable {
    public let hash: String
    public let explorerUrl: String?
}

public struct AuroraSwapDetails: Decodable, Sendable {
    public let amountOutFormatted: String?
    public let amountOutUsd: String?
    /// Origin / destination settlement txs. These are arrays of OBJECTS in Aurora's schema — decoding them as
    /// `[String]` (as an earlier version did) threw a typeMismatch the moment the deposit tx was recorded, which
    /// silently stalled the status poll at "Confirming your deposit…". Keep them as `AuroraTxRef`.
    public let originChainTxHashes: [AuroraTxRef]?
    public let destinationChainTxHashes: [AuroraTxRef]?
    public let refundedAmountFormatted: String?
    public let refundReason: String?
}
