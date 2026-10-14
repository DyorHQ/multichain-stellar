import BigInt
import Foundation

/// ERC-721 reads used by wallet asset discovery.
public enum ERC721 {
    public static func ownerOf(_ nft: Address, _ tokenId: BigUInt) throws -> ContractCall {
        try ContractCall(to: nft, "ownerOf(uint256)", [.uint(tokenId)], returns: "address")
    }

    public static func tokenURI(_ nft: Address, _ tokenId: BigUInt) throws -> ContractCall {
        try ContractCall(to: nft, "tokenURI(uint256)", [.uint(tokenId)], returns: "string")
    }

    public static func name(_ nft: Address) throws -> ContractCall { try ContractCall(to: nft, "name()", returns: "string") }
}

/// OpenSea pages for Monad. Item pages are addressed by contract and token id; a collection's own page uses a slug
/// OpenSea assigns, so the collection is reached through its first edition.
public enum OpenSea {
    public static func item(contract: Address, tokenId: BigUInt) -> URL {
        URL(string: "https://opensea.io/item/monad/\(contract.checksummed)/\(tokenId)")!
    }

    public static func collection(contract: Address) -> URL { item(contract: contract, tokenId: 1) }
}

/// One NFT a wallet holds, with what its metadata says about it.
public struct NFTAsset: Identifiable, Hashable, Sendable {
    public let contract: Address
    public let tokenId: BigUInt
    public let collection: String
    public let name: String
    public let imageURL: URL?
    public let animationURL: URL?

    public init(contract: Address, tokenId: BigUInt, collection: String, name: String, imageURL: URL?, animationURL: URL?) {
        self.contract = contract
        self.tokenId = tokenId
        self.collection = collection
        self.name = name
        self.imageURL = imageURL
        self.animationURL = animationURL
    }

    public var id: String { "\(contract.hex)-\(tokenId)" }
    public var openSeaURL: URL { OpenSea.item(contract: contract, tokenId: tokenId) }
}

/// ERC-721 metadata, reduced to what the app shows. Anyone can airdrop an NFT to a wallet, and its `tokenURI` and
/// image point wherever its contract says — a tracking server that learns the wallet's IP, or an endless or oversized
/// response (security audit 2026-09-26, IOST-12). So only content-addressed storage is ever fetched: an on-chain
/// `data:` document, IPFS (through `ipfsGateway`, whatever gateway the URI names) and Arweave. Anything else is not
/// fetched at all, and documents are read up to `maxDocumentBytes`.
public struct NFTMetadata: Sendable {
    public var name: String?
    public var image: URL?
    public var animation: URL?

    public init(name: String? = nil, image: URL? = nil, animation: URL? = nil) {
        self.name = name
        self.image = image
        self.animation = animation
    }

    /// The gateway every IPFS path is read through.
    public static let ipfsGateway = "https://ipfs.io/ipfs/"
    /// The most bytes read for one metadata document.
    public static let maxDocumentBytes = 512 * 1024
    private static let session = RemoteMedia.makeSession()

    public static func resolve(tokenURI: String, session: URLSession? = nil) async -> NFTMetadata? {
        let uri = tokenURI.trimmingCharacters(in: .whitespacesAndNewlines)
        var document: Data?
        if uri.lowercased().hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
            guard uri.utf8.count <= maxDocumentBytes * 2 else { return nil }
            let payload = String(uri[uri.index(after: comma)...])
            document = uri[..<comma].lowercased().contains(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
        } else if let url = gatewayURL(uri) {
            document = try? await RemoteMedia.fetch(url, session: session ?? Self.session, maxBytes: maxDocumentBytes)
        }
        guard let document, document.count <= maxDocumentBytes,
              let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any] else { return nil }
        let image = (object["image"] as? String) ?? (object["image_url"] as? String)
        let name = (object["name"] as? String).map { String($0.prefix(120)) }
        return NFTMetadata(name: name, image: image.flatMap(gatewayURL), animation: (object["animation_url"] as? String).flatMap(gatewayURL))
    }

    /// Where the app may read `uri` from, or nil when it points anywhere else: `ipfs://…`, and an https IPFS gateway
    /// link in either form (`https://<any host>/ipfs/<cid>/…`, `https://<cid>.ipfs.<host>/…`), through `ipfsGateway`;
    /// `ar://…` and `https://arweave.net/…` through arweave.net.
    public static func gatewayURL(_ uri: String) -> URL? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("ipfs://") { return IPFS.path(trimmed).flatMap(ipfs) }
        if lower.hasPrefix("ar://") { return arweave(String(trimmed.dropFirst("ar://".count))) }
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), components.user == nil, components.password == nil else { return nil }
        if host == "arweave.net" { return arweave(String(components.percentEncodedPath.dropFirst())) }
        // The path form (/ipfs/<cid>[/…] on any gateway) or the subdomain form (<cid>.ipfs.<gateway>/[…]).
        return IPFS.path(components).flatMap(ipfs)
    }

    /// A CID (optionally followed by a path inside it) through `ipfsGateway`, or nil when it isn't one: letters and
    /// digits, 2–128 of them (a looser test than `IPFS.isCID`, kept as NFT metadata has always read).
    private static func ipfs(_ cidAndPath: String) -> URL? {
        let cid = IPFS.cid(of: cidAndPath)
        guard (2...128).contains(cid.count), cid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return URL(string: ipfsGateway + cidAndPath)
    }

    /// An Arweave transaction id (optionally followed by a path) through arweave.net, or nil when it isn't one.
    private static func arweave(_ idAndPath: String) -> URL? {
        let id = idAndPath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard (32...64).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return URL(string: "https://arweave.net/" + idAndPath)
    }
}
