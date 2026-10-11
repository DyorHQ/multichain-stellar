import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StellarCore

/// Cash in / cash out through a SEP-24 anchor: read its stellar.toml (SEP-1), sign in with the account key (SEP-10),
/// open the anchor's interactive flow, then follow the transaction. The phone talks to the anchor directly; the
/// Lite API only records the anchor transaction id for Activity.
public struct AnchorClient: Sendable {
    public struct Toml: Equatable, Sendable {
        public let webAuth: URL
        public let transferServer: URL
        public let signingKey: String
        public let networkPassphrase: String?
    }

    public struct Interactive: Codable, Equatable, Sendable {
        public let type: String
        public let url: String
        public let id: String
    }

    public struct AnchorTransaction: Codable, Equatable, Sendable {
        public let id: String
        public let kind: String
        public let status: String
        public let amount_in: String?
        public let amount_out: String?
        public let amount_fee: String?
        public let more_info_url: String?
        public let withdraw_anchor_account: String?
        public let withdraw_memo: String?
        public let withdraw_memo_type: String?
        public let message: String?
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case toml(String)
        case challenge(String)
        case anchor(String)

        public var errorDescription: String? {
            switch self {
            case .toml(let w): return "This anchor's setup file is missing \(w)."
            case .challenge(let w): return "The anchor's sign-in didn't pass our checks (\(w))."
            case .anchor(let w): return w
            }
        }
    }

    public let domain: String
    public let network: StellarNetwork
    private let session: URLSession

    public init(domain: String, network: StellarNetwork, session: URLSession = .shared) {
        self.domain = domain
        self.network = network
        self.session = session
    }

    public func toml() async throws -> Toml {
        let data = try await get(URL(string: "https://\(domain)/.well-known/stellar.toml")!)
        let text = String(decoding: data, as: UTF8.self)
        func value(_ key: String) -> String? {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(key) else { continue }
                let rest = t.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                guard rest.hasPrefix("=") else { continue }
                return rest.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            return nil
        }
        guard let auth = value("WEB_AUTH_ENDPOINT").flatMap(URL.init(string:)) else { throw Failure.toml("WEB_AUTH_ENDPOINT") }
        guard let transfer = value("TRANSFER_SERVER_SEP0024").flatMap(URL.init(string:)) else { throw Failure.toml("TRANSFER_SERVER_SEP0024") }
        guard let key = value("SIGNING_KEY"), StrKey.isValid(.accountID, key) else { throw Failure.toml("SIGNING_KEY") }
        return Toml(webAuth: auth, transferServer: transfer, signingKey: key, networkPassphrase: value("NETWORK_PASSPHRASE"))
    }

    /// SEP-10: validates the challenge before signing it (server-signed, sequence 0, short-lived, only ManageData,
    /// the first one ours and named "<domain> auth"), then exchanges it for the anchor's token.
    public func authenticate(signer: StellarSigner, toml: Toml, now: Date = Date()) async throws -> String {
        var comps = URLComponents(url: toml.webAuth, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "account", value: signer.address)]
        struct Challenge: Decodable { let transaction: String; let network_passphrase: String? }
        let ch = try JSONDecoder().decode(Challenge.self, from: try await get(comps.url!))
        if let p = ch.network_passphrase, p != network.passphrase { throw Failure.challenge("wrong network") }
        var env = try TransactionEnvelope(base64: ch.transaction)
        try Self.validateChallenge(env, client: signer.address, serverKey: toml.signingKey, homeDomain: domain, network: network, now: now)
        try env.sign(with: signer, network: network)
        struct Token: Decodable { let token: String }
        let data = try await post(toml.webAuth, json: ["transaction": env.base64()], bearer: nil)
        return try JSONDecoder().decode(Token.self, from: data).token
    }

    static func validateChallenge(_ env: TransactionEnvelope, client: String, serverKey: String, homeDomain: String, network: StellarNetwork, now: Date) throws {
        let tx = env.transaction
        guard tx.source == serverKey else { throw Failure.challenge("source") }
        guard tx.sequence == 0 else { throw Failure.challenge("sequence") }
        guard let tb = tx.timeBounds, Double(tb.minTime) <= now.timeIntervalSince1970 + 60, Double(tb.maxTime) >= now.timeIntervalSince1970 else {
            throw Failure.challenge("time bounds")
        }
        guard let first = tx.operations.first, case let .manageData(name, _) = first.body, first.source == client, name == "\(homeDomain) auth" else {
            throw Failure.challenge("first operation")
        }
        for op in tx.operations.dropFirst() {
            guard case .manageData = op.body, op.source == serverKey || op.source == client else { throw Failure.challenge("operations") }
        }
        guard env.isSigned(by: serverKey, network: network) else { throw Failure.challenge("server signature") }
    }

    /// SEP-24 interactive deposit or withdrawal. Open `url` in an in-app browser; follow `id` with `transaction`.
    public func interactive(deposit: Bool, assetCode: String, account: String, jwt: String, toml: Toml) async throws -> Interactive {
        let path = deposit ? "transactions/deposit/interactive" : "transactions/withdraw/interactive"
        let data = try await post(toml.transferServer.appendingPathComponent(path), json: ["asset_code": assetCode, "account": account, "lang": "en"], bearer: jwt)
        return try JSONDecoder().decode(Interactive.self, from: data)
    }

    public func transaction(id: String, jwt: String, toml: Toml) async throws -> AnchorTransaction {
        var comps = URLComponents(url: toml.transferServer.appendingPathComponent("transaction"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "id", value: id)]
        struct R: Decodable { let transaction: AnchorTransaction }
        return try JSONDecoder().decode(R.self, from: try await get(comps.url!, bearer: jwt)).transaction
    }

    // ---------------------------------------------------------------------------------------------- http

    private func get(_ url: URL, bearer: String? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        return try await send(req)
    }

    private func post(_ url: URL, json: [String: String], bearer: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, status): (Data, Int) = try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: req) { d, r, e in
                if let e { return cont.resume(throwing: e) }
                cont.resume(returning: (d ?? Data(), (r as? HTTPURLResponse)?.statusCode ?? 0))
            }.resume()
        }
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure.anchor(msg ?? "The anchor answered \(status).")
        }
        return data
    }
}
