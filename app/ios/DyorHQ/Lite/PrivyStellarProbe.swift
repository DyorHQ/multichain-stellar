// Prototype only (Debug, internal app): how a Privy-held account's Stellar wallet authorizes raw_sign, against the
// local relay backend/scripts/privy-stellar-probe.ts. Runs once per launch when the app is launched with
// `-PrivyStellarProbe http://127.0.0.1:8790` and an Apple, Google, email-code or Privy-passkey account is signed in.
// Its findings go to the relay's report through /note: never a token.
#if STELLAR_LITE && DEBUG
import CryptoKit
import Foundation
import PrivySDK
import StellarKit

enum PrivyStellarProbe {
    private struct RawSign: Encodable {
        struct Params: Encodable { let hash: String }
        let params: Params
    }

    @MainActor private static var ran = false

    @MainActor
    static func runIfAsked(session: Session) async {
        guard !ran, let relay = UserDefaults.standard.string(forKey: "PrivyStellarProbe").flatMap(URL.init(string:)),
              let account = session.account, [.apple, .google, .email, .passkey].contains(account.method),
              let user = await session.privyUserForProbe() else { return }
        ran = true
        let appId = session.config.privyAppID
        do {
            try await run(relay: relay, user: user, appId: appId)
        } catch {
            await note(relay, ["step": "failed", "error": "\(error)"])
        }
    }

    private static func run(relay: URL, user: any PrivyUser, appId: String) async throws {
        let token = try await user.getAccessToken()
        let wallet = try await post(relay, "wallet", ["accessToken": token])
        guard let walletId = wallet["walletId"] as? String, let address = wallet["address"] as? String else {
            return await note(relay, ["step": "wallet", "answer": "\(wallet)"])
        }
        await note(relay, ["step": "wallet", "walletId": walletId, "address": address, "created": "\(wallet["created"] ?? "")"])

        // Does Privy itself (not our relay) show the phone this wallet? The identity token, then /users/me.
        try? await user.refresh()
        await note(relay, ["step": "identityToken", "present": "\(user.identityToken != nil)",
                           "listsStellarAddress": "\(identityTokenLists(address, user.identityToken))"])
        await note(relay, ["step": "usersMe", "result": await usersMeLists(address, token: try await user.getAccessToken(), appId: appId)])

        if let identityToken = user.identityToken {
            _ = try? await post(relay, "identity", ["identityToken": identityToken, "accessToken": try await user.getAccessToken(),
                                                     "address": address, "walletId": walletId])
        }

        // A testnet transaction from that address, its hash authorized on the phone, signed by Privy, checked here.
        let prep = try await post(relay, "prepare", ["address": address])
        guard let xdr = prep["xdr"] as? String, let hash = prep["hash"] as? String else {
            return await note(relay, ["step": "prepare", "answer": "\(prep)"])
        }
        let client = try await clientSign(relay: relay, user: user, appId: appId, walletId: walletId, hash: hash, expiry: true)
        await note(relay, ["step": "clientSign", "ok": "\(client.ok)", "verifies": "\(verifies(address, hash, client.signature))", "error": client.error ?? ""])
        var signature = client.signature
        if !client.ok {
            let plain = try await clientSign(relay: relay, user: user, appId: appId, walletId: walletId, hash: hash, expiry: false)
            await note(relay, ["step": "clientSignNoExpiry", "ok": "\(plain.ok)", "verifies": "\(verifies(address, hash, plain.signature))", "error": plain.error ?? ""])
            signature = plain.signature
        }

        // The relay changes the hash after the phone authorized another: Privy must refuse.
        var other = Array(hash)
        other[0] = other[0] == "0" ? "1" : "0"
        let tampered = try await clientSign(relay: relay, user: user, appId: appId, walletId: walletId, hash: hash, sendHash: String(other), expiry: true)
        await note(relay, ["step": "tampered", "refused": "\(!tampered.ok)", "error": tampered.error ?? ""])

        if let signature {
            let sent = try await post(relay, "submit", ["xdr": xdr, "signature": signature, "address": address])
            await note(relay, ["step": "submitted", "answer": "\(sent)"])
        }

        // SEP-53: the Lite API's sign-in challenge, signed the same way.
        let message = "DyorHQ probe \(Date().timeIntervalSince1970)"
        let digest = Data(SHA256.hash(data: Data(("Stellar Signed Message:\n" + message).utf8))).map { String(format: "%02x", $0) }.joined()
        let sep53 = try await clientSign(relay: relay, user: user, appId: appId, walletId: walletId, hash: digest, expiry: true)
        await note(relay, ["step": "sep53", "ok": "\(sep53.ok)", "verifies": "\(verifies(address, digest, sep53.signature))"])

        // The other model: the relay gets a user key for the token itself and authorizes what it likes.
        let server = try await post(relay, "sign", ["mode": "server", "accessToken": try await user.getAccessToken(),
                                                    "walletId": walletId, "hash": "0x" + hash])
        let serverSig = server["signature"] as? String
        await note(relay, ["step": "serverSign", "ok": "\(server["ok"] ?? "")", "verifies": "\(verifies(address, hash, serverSig))",
                           "error": "\(server["error"] ?? "")"])
    }

    private static func clientSign(relay: URL, user: any PrivyUser, appId: String, walletId: String, hash: String,
                                   sendHash: String? = nil, expiry: Bool) async throws -> (ok: Bool, signature: String?, error: String?) {
        var headers = ["privy-app-id": appId]
        if expiry { headers["privy-request-expiry"] = String(Int64((Date().timeIntervalSince1970 + 120) * 1000)) }
        let payload = WalletApiPayload(version: 1, url: "https://api.privy.io/v1/wallets/\(walletId)/raw_sign", method: "POST",
                                       headers: headers, body: RawSign(params: .init(hash: "0x" + hash)))
        let authorization: String
        do {
            authorization = try await user.generateAuthorizationSignature(payload: payload)
        } catch {
            return (false, nil, "generateAuthorizationSignature: \(error)")
        }
        let answer = try await post(relay, "sign", ["mode": "client", "accessToken": try await user.getAccessToken(), "walletId": walletId,
                                                    "hash": "0x" + (sendHash ?? hash), "authorizationSignature": authorization, "headers": headers])
        let signature = answer["signature"] as? String
        return (signature != nil, signature, signature == nil ? "\(answer["status"] ?? "") \(answer["error"] ?? "")" : nil)
    }

    private static func verifies(_ address: String, _ hashHex: String, _ signatureHex: String?) -> Bool {
        guard let signatureHex, let message = bytes(hashHex), let signature = bytes(signatureHex) else { return false }
        return StellarSigner.verify(address: address, message: message, signature: signature)
    }

    private static func bytes(_ hex: String) -> [UInt8]? {
        let h = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard h.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// Whether the identity token's linked_accounts (a JSON string claim) names the address.
    private static func identityTokenLists(_ address: String, _ token: String?) -> Bool {
        guard let token, let claims = jwtClaims(token) else { return false }
        return "\(claims["linked_accounts"] ?? "")".contains(address)
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Privy's own user record for the token (auth.privy.io, as the SDK reads it): its status, and whether it lists the
    /// address among the linked accounts.
    private static func usersMeLists(_ address: String, token: String, appId: String) async -> String {
        var req = URLRequest(url: URL(string: "https://auth.privy.io/api/v1/users/me")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(appId, forHTTPHeaderField: "privy-app-id")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return "no answer" }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        let types = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["user"] as? [String: Any] ?? $0 }
            .flatMap { $0["linked_accounts"] as? [[String: Any]] }?.map { "\($0["type"] ?? "")/\($0["chain_type"] ?? "")" } ?? []
        return "status \(status), lists \(text.contains(address)), accounts \(types)"
    }

    private static func post(_ relay: URL, _ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: relay.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func note(_ relay: URL, _ detail: [String: String]) async {
        _ = try? await post(relay, "note", ["detail": detail])
    }
}
#endif
