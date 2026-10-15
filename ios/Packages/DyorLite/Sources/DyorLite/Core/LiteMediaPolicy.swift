import Foundation

/// Which media the Stellar screens load (docs/DESIGN-stellar-parity.md §3.8, §5.6): only DyorHQ's own uploads, under the
/// build's pinned media base (`LiteEnvironment.mediaBase`), never a URL the server or a metadata file could point
/// anywhere else. Anything else gives no source, and the view shows letters or its placeholder art.
///
/// An upload is `<base>uploads/<the uploader's G…>/<a uuid>.<ext>`: https (plain http only when the base itself is the
/// loopback stand-in of a Debug build), the base's exact host and port, no user, query or fragment, nothing but that
/// path after the base, and at most 2,048 bytes in all.
public enum LiteMediaPolicy {
    /// Images: jpg, jpeg, png, webp, gif. Videos: mp4, mov.
    static let imageTypes: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]
    static let videoTypes: Set<String> = ["mp4", "mov"]
    /// The largest width Storage's renderer is asked for; above it, the original.
    static let maxRenderWidth = 768
    static let maxLength = 2048

    /// The image sources for `uri`, best first: Storage's render at `pixels` wide (only with a render base, never for
    /// a gif or above 768 px), then the original. `[]` for anything that isn't an image upload under `base`.
    public static func imageSources(_ uri: String, base: URL, renderBase: URL?, pixels: Int?) -> [URL] {
        guard let path = upload(uri, base: base, types: imageTypes), let original = URL(string: uri) else { return [] }
        guard let renderBase, isTrusted(renderBase), let pixels, (1...maxRenderWidth).contains(pixels), !path.hasSuffix(".gif"),
              let render = URL(string: renderBase.absoluteString + path + "?width=\(pixels)&resize=contain&quality=70") else {
            return [original]
        }
        return [render, original]
    }

    /// The video at `uri` (mp4 or mov) when it is an upload under `base`; nil otherwise.
    public static func videoURL(_ uri: String, base: URL) -> URL? {
        guard upload(uri, base: base, types: videoTypes) != nil else { return nil }
        return URL(string: uri)
    }

    /// The path of `uri` below `base` ("uploads/G…/<uuid>.<ext>") when it is an upload of one of `types` there.
    static func upload(_ uri: String, base: URL, types: Set<String>) -> String? {
        let prefix = base.absoluteString
        guard isTrusted(base), prefix.hasSuffix("/"), uri.utf8.count <= maxLength, uri.hasPrefix(prefix) else { return nil }
        let path = String(uri.dropFirst(prefix.count))
        guard isUploadPath(path, types: types), let url = URL(string: uri), url.scheme == base.scheme, url.host == base.host,
              url.port == base.port, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return path
    }

    /// "uploads/" + a 56-character G… + "/" + 36 of 0–9, a–f and "-" + "." + one of `types`, and nothing else.
    private static func isUploadPath(_ path: String, types: Set<String>) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "uploads" else { return false }
        let owner = parts[1]
        guard owner.utf8.count == 56, owner.first == "G",
              owner.utf8.allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) || (UInt8(ascii: "2")...UInt8(ascii: "7")).contains($0) }) else {
            return false
        }
        let name = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard name.count == 2, types.contains(String(name[1])), name[0].utf8.count == 36,
              name[0].utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) || $0 == UInt8(ascii: "-") }) else {
            return false
        }
        return true
    }

    /// A base the screens may load from: https, or plain http on the loopback (Debug's local stand-in); no user, query
    /// or fragment.
    static func isTrusted(_ base: URL) -> Bool {
        guard base.user == nil, base.password == nil, base.query == nil, base.fragment == nil, let host = base.host, !host.isEmpty else { return false }
        switch base.scheme {
        case "https": return true
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(host)
        default: return false
        }
    }
}
