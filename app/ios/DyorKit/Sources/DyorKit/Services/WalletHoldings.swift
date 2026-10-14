import BigInt
import Foundation

/// One token the wallet holds: its balance and, when a pool prices it, its dollar value. The Portfolio's Assets and
/// the Send sheet's list are both made of these, from the same read (`WalletHoldings.ranked`), so the two hold the same
/// tokens and can't drift; each keeps its own order.
public struct HeldToken: Hashable, Sendable, Identifiable {
    public let token: Token
    public let balance: BigUInt
    /// USD per whole token; nil when no pool prices it.
    public let usd: Double?
    /// Reached the wallet without being chosen in the app (sent, airdropped): its name and symbol prove nothing, so it
    /// is marked Unverified wherever it is listed (security audit 2026-09-26, IOST-12).
    public let unverified: Bool

    public init(token: Token, balance: BigUInt, usd: Double?, unverified: Bool = false) {
        self.token = token
        self.balance = balance
        self.usd = usd
        self.unverified = unverified
    }

    public var id: Address { token.address }
    /// The curated token this one could pass for, by its symbol or name (`WalletHoldings.imitated(by:)`); nil for the
    /// curated tokens and anything named otherwise, and nil for a look-alike of a widely traded token DyorHQ doesn't list
    /// (`WalletHoldings.majorTokens`). The screens word both kinds through `TokenBadge.title` ("Not the USDC DyorHQ lists",
    /// "Not the real BTC"), and a send's default leaves both out (`looksAlike`). Read again, it costs a look-up
    /// (`imitated(by:)` keeps its answers).
    public var imitates: Token? { WalletHoldings.imitated(by: token, majors: false) }
    /// It could pass for a curated token or a widely traded one (`WalletHoldings.imitated(by:)`); as cheap to read
    /// again.
    public var looksAlike: Bool { WalletHoldings.imitated(by: token) != nil }
    /// Its symbol is plain printable ASCII (`WalletHoldings.isPlain`), as MON's and every curated token's is: one with any
    /// other character — invisible, direction-changing, a letter from another script — can read as a symbol it isn't.
    public var plainSymbol: Bool { token.isNative || Token.core(token.address) != nil || WalletHoldings.isPlain(token.symbol) }
    /// Whole tokens held.
    public var units: Double { Amount.units(balance, decimals: token.decimals) }
    /// Dollar value: nil when the price is unknown, never $0 in its place.
    public var value: Double? {
        guard let usd else { return nil }
        let value = units * usd
        return value.isFinite ? value : nil
    }
}

/// Which tokens the wallet holds, in what order, and which one a send starts on. Pure, so it is tested here; the app
/// reads the balances and prices it works on (`WalletTokens`).
public enum WalletHoldings {
    /// The tokens of `universe` the wallet holds — a balance above zero — each once, in `universe` order. A token whose
    /// balance is missing (its read failed) is left out, as it always was on the Portfolio.
    public static func held(_ universe: [Token], balances: [Address: BigUInt]) -> [Token] {
        var seen = Set<Address>()
        return universe.filter { (balances[$0.address] ?? 0) > 0 && seen.insert($0.address).inserted }
    }

    /// `tokens` with their balances and prices (USD per whole token), ranked by `order`: the Send list's (`precedes`)
    /// unless another is given (the Portfolio's, `portfolioPrecedes`). Tokens with no balance are left out here too.
    public static func ranked(_ tokens: [Token], balances: [Address: BigUInt], prices: [Address: Double], unverified: Set<Address>,
                              by order: (HeldToken, HeldToken) -> Bool = precedes) -> [HeldToken] {
        held(tokens, balances: balances)
            .map { HeldToken(token: $0, balance: balances[$0.address] ?? 0, usd: prices[$0.address], unverified: unverified.contains($0.address)) }
            .sorted(by: order)
    }

    /// The order the Portfolio's Assets has always used, unchanged: dollar value, highest first, a token with no price
    /// counted as $0, then the larger amount held.
    public static func portfolioPrecedes(_ a: HeldToken, _ b: HeldToken) -> Bool {
        (a.value ?? 0, a.units) > (b.value ?? 0, b.units)
    }

    /// The Send list's order:
    /// 1. dollar value, highest first; every token with no price comes after every priced one, never ranked as $0;
    /// 2. then tokens the user chose before Unverified ones;
    /// 3. then the larger amount held (whole tokens);
    /// 4. then symbol A–Z, ignoring case, then contract address — so the order never depends on the order of the reads.
    public static func precedes(_ a: HeldToken, _ b: HeldToken) -> Bool {
        switch (a.value, b.value) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.unverified != b.unverified { return !a.unverified }
        if a.units != b.units { return a.units > b.units }
        switch a.token.symbol.compare(b.token.symbol, options: .caseInsensitive) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.token.address.hex < b.token.address.hex
        }
    }

    /// The asset a send starts on: the highest-ranked one the user chose. Never an Unverified token — a fake "USDC"
    /// with a seeded pool can outrank everything — nor one carrying a curated or widely traded token's name
    /// (`looksAlike`), even one the user tapped in Swap, nor one whose symbol isn't plain (`plainSymbol`): it may be a
    /// look-alike, and a send must never start on it unasked. So when every held token is one of those, or nothing is
    /// held, there is none and the user picks. None either when the prices couldn't be read (`pricesRead` false), and
    /// never a token with no price: the list below the priced tokens is by amount, not value, and the token with the
    /// most units is not the one worth the most.
    public static func defaultChoice(_ ranked: [HeldToken], pricesRead: Bool = true) -> HeldToken? {
        guard pricesRead else { return nil }
        return ranked.first { ($0.usd ?? 0) > 0 && !$0.unverified && !$0.looksAlike && $0.plainSymbol }
    }

    /// After the list is read: with nothing chosen yet, the default choice; with a choice, that token while the wallet
    /// still holds it, and none once it doesn't — the user picks again, rather than a send switching to another asset
    /// under an amount already typed.
    public static func selection(keeping current: Address?, in ranked: [HeldToken], pricesRead: Bool = true) -> HeldToken? {
        guard let current else { return defaultChoice(ranked, pricesRead: pricesRead) }
        return ranked.first { $0.id == current }
    }

    /// The held tokens a search matches, in `held` order: a pasted address matches that contract only; other text
    /// matches the symbol or name as the list shows it (`displayName`), or — starting with 0x — the start of the
    /// contract address.
    public static func matching(_ held: [HeldToken], query: String) -> [HeldToken] {
        let text = Address.cleanedInput(query).text
        guard !text.isEmpty else { return held }
        if let address = Address(text) { return held.filter { $0.token.address == address } }
        let hex = text.lowercased()
        return held.filter { item in
            item.token.symbol.localizedCaseInsensitiveContains(text) || item.token.displayName.localizedCaseInsensitiveContains(text)
                || (hex.hasPrefix("0x") && hex.count >= 4 && item.token.address.hex.hasPrefix(hex))
        }
    }

    /// `prices` (USD per whole token, from the pool finder) with DyorHQ's own coins valued as the app values them, which
    /// the pool finder can't: a launch coin (`launches`, found by its factory's record) at its live price in its pair
    /// asset (`HeldLaunches.pairPerCoin`: its curve's, or its pool's once graduated) times that asset's dollar price in
    /// `prices`; a Moment coin (`moments`) at its pool's live USDC price (`momentPrice`). Such a coin is never valued at a
    /// price another pool quotes for it: without the app's own value (a launch or price that couldn't be read, a pair
    /// asset with no price, a Moment whose pool wasn't read) it is unpriced.
    public static func pricing(_ prices: [Address: Double], launches: HeldLaunches, moments: [Address: Double?]) -> [Address: Double] {
        var out = prices
        for (coin, pair) in launches.pairAssets {
            // MON's price is under its address, 0 — the pair asset a native launch records.
            let usd = launches.pairPerCoin[coin].flatMap { perCoin in prices[pair].map { perCoin * $0 } }
            out[coin] = usd.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        for (coin, usdcPerCoin) in moments { out[coin] = usdcPerCoin }
        return out
    }

    /// A Moment coin's dollar price for `pricing`: its pool's USDC price as read live. Nil when that read failed — never
    /// the pool's opening price in its place — or the Moment has no pool.
    public static func momentPrice(_ info: MomentInfo) -> Double? {
        guard let pool = info.pool, pool.livePriceRead, pool.usdcPerCoin.isFinite, pool.usdcPerCoin > 0 else { return nil }
        return pool.usdcPerCoin
    }

    /// The DyorHQ coins that are `owner`'s own: a launch coin it launched (its factory records the wallet as deployer —
    /// the factory's caller, or the launch router's, never an argument) and a Moment coin whose Moment it collected or
    /// created (`staked`: a stake in the Moment's vesting). The factories name each coin by its address, so no look-alike
    /// passes for one; a coin that was only sent to the wallet is not its own.
    public static func ownCoins(owner: Address, launches: HeldLaunches, staked: Set<Address>) -> Set<Address> {
        Set(launches.deployers.filter { $0.value == owner }.keys).union(staked)
    }

    /// `unverified` without the DyorHQ coins that are `owner`'s own (`ownCoins`): a coin that was only sent to the wallet
    /// stays Unverified.
    public static func unverified(_ unverified: Set<Address>, owner: Address, launches: HeldLaunches, staked: Set<Address>) -> Set<Address> {
        unverified.subtracting(ownCoins(owner: owner, launches: launches, staked: staked))
    }

    /// The token `token` could pass for: a curated one, or a widely traded one DyorHQ doesn't list (`majorTokens`).
    /// `token` is none of them, yet
    /// - its symbol or name reads as one of their symbols or names (`readings`) — a second "USDC", a "Monad" that isn't
    ///   MON, a "USDC" with a zero-width space or a Cyrillic "С" in it, "M0N", "m0nad", "MØN", "U$DC", a Lisu "ꓟꓳꓠ", a
    ///   Myanmar "Mဝnad", a "USDT";
    /// - or its symbol holds one of their symbols or names with no letter right before or after it — "USDC.e", "$MON",
    ///   "MON2", "MON०" with a Devanagari zero, "USDC©", "USDC e", "USDC" padded with spaces and a dot — while letters
    ///   around it make another word ("MONKE", "xMON"). A digit of any script and a sign are no letters here (`forms`);
    /// - or its name is one of their symbols or names with nothing but non-letters around it ("$MON", "USDC 2",
    ///   "MON₹").
    /// Being chosen proves nothing here: tapping a search result in Swap stores a token as chosen. Nil for MON, the
    /// curated tokens and every other name. The badge (`TokenBadge`), the create forms' guard
    /// (`SymbolSafety.createRefusal`) and a send's default go by this one rule; so do the wallet's warnings, the major
    /// tokens aside (`HeldToken.imitates`). Only the first `maxJudged` characters that show of each are judged, so its
    /// cost doesn't grow with what a creator writes, and the answer for a symbol and name judged lately is kept
    /// (`Answers`), so a list drawn again judges nothing again.
    public static func imitated(by token: Token, majors: Bool = true) -> Token? {
        guard !token.isNative, Token.core(token.address) == nil else { return nil }
        let question = Answers.Question(symbol: token.symbol, name: token.name, majors: majors)
        if let kept = answers.answer(question) { return kept }
        let found = judge(token, majors: majors)
        answers.keep(found, for: question)
        return found
    }

    /// `imitated(by:)` worked out, for a token that is neither MON nor curated.
    private static func judge(_ token: Token, majors: Bool) -> Token? {
        let own = [token.symbol, token.name].flatMap(readings)
        guard !own.isEmpty else { return nil }
        let targets = majors ? lookAlikeTargets : curatedTargets
        if let first = own.compactMap({ targetReading[$0] }).filter({ $0 < targets.count }).min() { return targets[first].token }
        let symbol = forms(token.symbol).map(Text.init)
        let name = forms(token.name).map(Text.init)
        // A form needing an ASCII character none of these holds is in none of them: most are passed over on that alone.
        let held = (symbol + name).reduce(into: Text.ASCIISet()) { $0.formUnion($1.ascii) }
        return targets.first { target in
            target.forms.contains { wanted in
                held.isSuperset(of: wanted.ascii) && (symbol.contains { $0.standsApart(wanted) } || name.contains { $0.standsAlone(wanted) })
            }
        }?.token
    }

    /// The answers `imitated(by:)` gave lately, by symbol, name and whether the major tokens counted: at most `limit`,
    /// all dropped when it is reached, and only for a symbol and name short enough to keep (`maxKeptBytes` together,
    /// far more than any screen shows), so a crafted 40 KB name is judged each time, at its bounded cost, and never
    /// kept. Safe to use from any thread.
    final class Answers: @unchecked Sendable {
        struct Question: Hashable {
            let symbol: String
            let name: String
            let majors: Bool
        }

        static let limit = 512
        static let maxKeptBytes = 512
        private let lock = NSLock()
        private var kept: [Question: Token?] = [:]

        /// The answer kept for `question`: the token it imitates, `.some(nil)` for none, or nil when none is kept.
        func answer(_ question: Question) -> Token?? {
            lock.lock(); defer { lock.unlock() }
            return kept[question]
        }

        func keep(_ answer: Token?, for question: Question) {
            guard question.symbol.utf8.count + question.name.utf8.count <= Self.maxKeptBytes else { return }
            lock.lock(); defer { lock.unlock() }
            if kept.count >= Self.limit { kept.removeAll(keepingCapacity: true) }
            kept[question] = .some(answer)
        }
    }

    private static let answers = Answers()

    /// Widely traded tokens DyorHQ doesn't list, which a coin may not pass for either: BTC, ETH, SOL, USDT, DAI and BNB,
    /// each with its usual name. None has a contract on Monad the app knows, so each carries a placeholder address no key
    /// or contract has (`placeholder`): it names what a look-alike imitates, and is never read, priced or sent.
    public static let majorTokens: [Token] = majors.map(\.token)

    /// Each major token with the names it goes by.
    private static let majors: [(token: Token, names: [String])] = [
        (major("BTC", "Bitcoin"), ["Bitcoin"]), (major("ETH", "Ethereum"), ["Ethereum"]), (major("SOL", "Solana"), ["Solana"]),
        (major("USDT", "Tether USD"), ["Tether", "Tether USD"]), (major("DAI", "Dai"), ["Dai"]), (major("BNB", "BNB"), ["BNB"]),
    ]

    private static func major(_ symbol: String, _ name: String) -> Token {
        Token(address: placeholder(symbol), symbol: symbol, name: name, decimals: 18)
    }

    /// The last 20 bytes of keccak-256("DyorHQ major token <symbol>"): an address nobody holds a key or code for.
    static func placeholder(_ symbol: String) -> Address {
        Address(data: Keccak.hash256(Data("DyorHQ major token \(symbol)".utf8)).suffix(20))!
    }

    /// A token a coin may not pass for, with the readings (`readings`) and lower-case forms (`forms`) of its symbol and
    /// names, worked out once.
    private struct LookAlikeTarget {
        let token: Token
        let readings: Set<String>
        let forms: [Text]

        init(_ token: Token, names: [String]) {
            self.token = token
            readings = Set(([token.symbol] + names).flatMap(WalletHoldings.readings))
            forms = Set(([token.symbol] + names).flatMap(WalletHoldings.forms)).map(Text.init)
        }
    }

    /// The curated tokens, then the major ones.
    private static let lookAlikeTargets: [LookAlikeTarget] = curatedTargets + majors.map { LookAlikeTarget($0.token, names: $0.names) }
    private static let curatedTargets: [LookAlikeTarget] = Token.core.map { LookAlikeTarget($0, names: [$0.name]) }

    /// Each reading of a target, with the first target in `lookAlikeTargets` that reads so: the curated ones come
    /// first, so one below `curatedTargets.count` is curated. A token's readings are each looked up once here, not
    /// compared with every target's.
    private static let targetReading: [String: Int] = {
        var first: [String: Int] = [:]
        for (index, target) in lookAlikeTargets.enumerated() {
            for reading in target.readings where first[reading] == nil { first[reading] = index }
        }
        return first
    }()

    /// The most of a symbol or name `imitated(by:)` judges: its first 128 characters that show (`visible`), or, when a
    /// direction override can show its end first, its last 128 too. No curated or major token's symbol or name comes
    /// near that (the longest, "Lombard Staked Bitcoin", has 22), a screen shows fewer, and a DyorHQ coin keeps fewer
    /// of a name (`DyorCoin.maxStoredName`); so a 40 KB name an airdropped token computes costs what a short one does.
    static let maxJudged = 128

    /// A form of a symbol or name (`forms`), as scalars, for finding one in another: at most `maxJudged` characters and
    /// a few more a compatibility form spells out, so each search is short. Letters are what `Character.isLetter` calls
    /// one (alphabetic), each worked out once.
    struct Text {
        let scalars: [Unicode.Scalar]
        /// Whether each scalar is a letter.
        let isLetter: [Bool]
        let letters: Int
        /// Which ASCII characters it holds: a text lacking one of another's can't hold that other, which settles most
        /// searches without one.
        let ascii: ASCIISet

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
            isLetter = scalars.map { $0.isASCII ? ("a"..."z").contains($0) || ("A"..."Z").contains($0) : $0.properties.isAlphabetic }
            letters = isLetter.reduce(0) { $0 + ($1 ? 1 : 0) }
            var ascii = ASCIISet()
            for scalar in scalars where scalar.isASCII { ascii.insert(scalar) }
            self.ascii = ascii
        }

        /// A set of ASCII characters, one bit each.
        struct ASCIISet {
            private var low: UInt64 = 0
            private var high: UInt64 = 0

            mutating func insert(_ scalar: Unicode.Scalar) {
                if scalar.value < 64 { low |= 1 << UInt64(scalar.value) } else { high |= 1 << UInt64(scalar.value - 64) }
            }

            mutating func formUnion(_ other: ASCIISet) {
                low |= other.low
                high |= other.high
            }

            func isSuperset(of other: ASCIISet) -> Bool { other.low & ~low == 0 && other.high & ~high == 0 }
        }

        /// Whether `wanted` is in it with no letter right before or after it.
        func standsApart(_ wanted: Text) -> Bool {
            holds(wanted) { start, end in !(start > 0 && isLetter[start - 1]) && !(end < scalars.count && isLetter[end]) }
        }

        /// Whether `wanted` is in it with no letter anywhere else in it: every letter it has is one of `wanted`'s.
        func standsAlone(_ wanted: Text) -> Bool {
            letters == wanted.letters && holds(wanted) { _, _ in true }
        }

        /// Whether `wanted` is in it at a place `fits` takes (by where it starts and ends), in one pass that stops at
        /// the first.
        private func holds(_ wanted: Text, where fits: (Int, Int) -> Bool) -> Bool {
            let count = wanted.scalars.count
            guard count > 0, count <= scalars.count, ascii.isSuperset(of: wanted.ascii) else { return false }
            let first = wanted.scalars[0]
            for start in 0 ... scalars.count - count where scalars[start] == first {
                var at = 1
                while at < count, scalars[start + at] == wanted.scalars[at] { at += 1 }
                if at == count, fits(start, start + count) { return true }
            }
            return false
        }
    }

    /// Whether `wanted` is in `text` with no letter right before or after it (`Text.standsApart`).
    static func standsApart(_ wanted: String, in text: String) -> Bool { Text(text).standsApart(Text(wanted)) }

    /// Whether `wanted` is in `text` with no letter anywhere else in it (`Text.standsAlone`).
    static func standsAlone(_ wanted: String, in text: String) -> Bool { Text(text).standsAlone(Text(wanted)) }

    /// The ways `text` reads to the eye, for `imitated(by:)`: `visible(text)` ignoring case (tagged "a"); with the digits
    /// and letters that pass for one another made one — 0 as O; 1, I and | as l — keeping case (tagged "b"), so "USDL"
    /// stays apart from "USD1"; ignoring case with only 0 read as o (tagged "c"), so "M0n", "wm0n" and "usdto" read as
    /// MON, WMON and USDT0 while "USDL" still isn't "USD1"; and ignoring case with what ASCII writes in a letter's place
    /// read as that letter (`asciiLookAlikes`, tagged "d"), so "U$DC", "WrnON", "VVMON" and "B1tcoin" read as USDC, WMON
    /// and Bitcoin. Text with a direction-changing character is read backwards too: an override can show "CDSU" as
    /// "USDC". Empty text has no reading.
    static func readings(_ text: String) -> [String] {
        shownForms(text, digits: .lookAlike).flatMap { form in
            ["a:" + form.lowercased(), "b:" + String(String.UnicodeScalarView(form.unicodeScalars.map { lookAlikeDigits[$0] ?? $0 })),
             "c:" + zeroAsO(form.lowercased()), "d:" + asciiLookAlikes(form.lowercased())]
        }
    }

    /// `text`'s readings "a", "c" and "d" untagged, for finding a token's symbol or name inside other text: each as
    /// `visible` gives it, and each with its spaces kept, one for each run of them, so a space parts a word as any
    /// other character that isn't a letter does ("USDC e"). A digit of another script is read as its value here,
    /// never as the letter it is drawn like (`Digits.value`): the rule asks whether a letter stands right beside a
    /// symbol, and a Devanagari "०" or an Arabic-Indic "٥" after "MON" is a digit, as the 0 in "MON0" is.
    static func forms(_ text: String) -> [String] {
        Array(Set((shownForms(text, digits: .value) + shownForms(text, keepingSpaces: true, digits: .value)).flatMap { form -> [String] in
            let lower = form.lowercased()
            return [lower, zeroAsO(lower), asciiLookAlikes(lower)]
        }))
    }

    /// `visible(text)`, and backwards too when a direction-changing character can show it so (its end, then, is what
    /// shows first); none for empty text.
    private static func shownForms(_ text: String, keepingSpaces: Bool = false, digits: Digits) -> [String] {
        let base = visible(text, keepingSpaces: keepingSpaces, digits: digits)
        guard !base.isEmpty else { return [] }
        guard changesDirection(text) else { return [base] }
        return [base, String(visible(text, keepingSpaces: keepingSpaces, fromTheEnd: true, digits: digits).reversed())]
    }

    /// Whether `text` holds a character that can change the order it shows in (`bidiControls`), leaving out a first
    /// strong isolate and its pop directional isolate around all of it, which is how `ChainText.shown` gives a creator's
    /// right-to-left name to a screen: that isolate takes its direction from the text's first letter, so it reverses
    /// nothing, and the shown "NOM ١" is no "١MON".
    private static func changesDirection(_ text: String) -> Bool {
        var scalars = Substring(text).unicodeScalars[...]
        if scalars.count > 1, scalars.first?.value == 0x2068, scalars.last?.value == 0x2069 { scalars = scalars.dropFirst().dropLast() }
        return scalars.contains { bidiControls.contains($0.value) }
    }

    private static func zeroAsO(_ text: String) -> String { text.replacingOccurrences(of: "0", with: "o") }

    /// Lower-case `text` with what ASCII writes in a letter's place read as that letter, as UTS #39 skeletons do for
    /// letters of other scripts: "rn" as m, "vv" as w, 0 as o, 1 as i, and $ between two letters as s ("U$DC"; a "$"
    /// before a ticker is the ticker's sign, and "$MON" reads as MON, not sMON).
    private static func asciiLookAlikes(_ text: String) -> String {
        let scalars = Array(text.replacingOccurrences(of: "rn", with: "m").replacingOccurrences(of: "vv", with: "w").unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            if scalar == "$", i > 0, i + 1 < scalars.count, scalars[i - 1].properties.isAlphabetic, scalars[i + 1].properties.isAlphabetic {
                out.append("s")
            } else {
                out.append(asciiLetters[scalar] ?? scalar)
            }
        }
        return String(out)
    }

    private static let asciiLetters: [Unicode.Scalar: Unicode.Scalar] = ["0": "o", "1": "i"]

    /// `text` as it shows, at most `maxJudged` characters of it (the first, or `fromTheEnd` the last): compatibility forms
    /// (full-width and mathematical letters) as their plain letters; invisible, format and direction characters
    /// (zero-width spaces and joiners, soft hyphen, byte-order mark, overrides), control characters, combining marks,
    /// the blank Braille pattern U+2800 and spaces removed (or, `keepingSpaces`, each run of spaces as one); U+FFFD
    /// removed too, which is what bytes that aren't text read as (`ABI.StringDecoding.lossy`) and draws as a mark, not a
    /// letter, so "USDC" and one such byte still reads as "USDC"; letters from other scripts that look like Latin ones
    /// (Cyrillic "С", Greek "Ο", Armenian "օ", Lisu "ꓟ", Myanmar "ဝ", Hebrew "ס", small capital "ᴏ": `lookAlikeLetters`)
    /// and Latin letters with a stroke, bar or hook (Ø, Đ, Ł, Ɵ, Ʉ: `LookAlikeLetters.marked`) as the letters they are
    /// drawn like, before the compatibility forms are folded (which would turn a Greek lunate "Ϲ" into a "Σ" nobody
    /// mistakes for C) and after; accents and width ignored; and every other Latin letter as the ASCII it is written
    /// with (`latinASCII`: the small capitals of "ᴍᴏɴᴀᴅ", Ƀ, Ȼ, Æ). A digit of another script is read as `digits`
    /// says: as the letter it is drawn like (a Devanagari "०" as o), or as its value. Signs and symbols stay as they
    /// are: none is spelled with letters ("©" is no "(C)", "₹" no "INR"), so one beside a symbol is still no letter.
    /// Case is kept (`readings` decides on it).
    static func visible(_ text: String, keepingSpaces: Bool = false, fromTheEnd: Bool = false, digits: Digits = .lookAlike) -> String {
        // Printable ASCII and spaces, short enough to show whole, is as it is written, its spaces removed or each run
        // of them one space: no table, compatibility form, accent, width or Latin letter to read.
        let bytes = text.utf8
        if bytes.count <= maxJudged, !bytes.contains(where: { $0 < 0x20 || $0 >= 0x7F }) {
            var out: [UInt8] = []
            var space = false
            for byte in bytes {
                if byte == 0x20 {
                    space = true
                    continue
                }
                if keepingSpaces, space, !out.isEmpty { out.append(0x20) }
                space = false
                out.append(byte)
            }
            return String(decoding: out, as: UTF8.self)
        }
        // What shows, at most `maxJudged` of it, taken before anything else, so a long text costs no more.
        var shown: [Unicode.Scalar] = []
        var space = false
        var plain = true
        for scalar in fromTheEnd ? AnyIterator(text.unicodeScalars.reversed().makeIterator()) : AnyIterator(text.unicodeScalars.makeIterator()) {
            if isSpace(scalar) {
                space = true
                continue
            }
            if isUnseen(scalar) { continue }
            if keepingSpaces, space, !shown.isEmpty { shown.append(" ") }
            space = false
            let read = read(scalar, digits)
            plain = plain && read.isASCII
            shown.append(read)
            if shown.count >= maxJudged { break }
        }
        if fromTheEnd { shown.reverse() }
        // Plain ASCII shows as it is written: no compatibility form, accent, width or Latin letter to fold.
        if plain { return String(String.UnicodeScalarView(shown)) }
        let composed = String(String.UnicodeScalarView(shown)).precomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        space = false
        for scalar in composed.unicodeScalars {
            if isSpace(scalar) {
                space = true
                continue
            }
            if isUnseen(scalar) { continue }
            if keepingSpaces, space, !scalars.isEmpty { scalars.append(" ") }
            space = false
            scalars.append(read(scalar, digits))
        }
        let folded = String(scalars).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        var ascii = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if let spelled = latinASCII[scalar] { ascii.append(contentsOf: spelled.unicodeScalars) } else { ascii.append(scalar) }
        }
        let shownText = String(ascii)
        return String((keepingSpaces ? shownText : shownText.filter { !$0.isWhitespace }).prefix(maxJudged))
    }

    /// How `visible` reads a decimal digit of another script that is drawn like a Latin letter (a Devanagari or Thai
    /// zero like o, an Arabic-Indic one like l, seven like V: `lookAlikeLetters`).
    enum Digits {
        /// As that letter, for `readings`, which compare whole symbols and names: "M०N" reads as MON.
        case lookAlike
        /// As the ASCII digit of its value, which is no letter, for `forms`, which find a symbol or name inside other
        /// text: "MON०" is MON with a digit after it, as "MON0" is.
        case value
    }

    /// `scalar` as `visible` reads it: a letter or digit of `readAs` as the one it is drawn like, and with `digits`
    /// `.value` every decimal digit (Unicode's Nd) as the ASCII digit of its value; anything else as it is.
    private static func read(_ scalar: Unicode.Scalar, _ digits: Digits) -> Unicode.Scalar {
        if scalar.isASCII { return scalar }
        if digits == .value, scalar.properties.generalCategory == .decimalNumber, let value = scalar.properties.numericValue,
           let ascii = Unicode.Scalar(UInt32(0x30) + UInt32(value)) {
            return ascii
        }
        return readAs[scalar] ?? scalar
    }

    /// Each Latin letter beyond ASCII that ICU's Latin-ASCII transform writes with ASCII, with what it writes: the
    /// small capitals and IPA letters, Æ as AE, ß as ss, and the spacing modifier letters, ʼ as an apostrophe. Letters
    /// only: the transform also spells signs with letters (© as "(C)", ₹ as "INR", ₺ as "TL"), which would put a letter
    /// beside a symbol that has none. Built once, from the Latin blocks, with one run of the transform.
    static let latinASCII: [Unicode.Scalar: String] = {
        let blocks: [ClosedRange<UInt32>] = [
            0x00AA...0x00AA, 0x00BA...0x00BA, 0x00C0...0x024F, 0x0250...0x02AF, 0x02B0...0x02FF, 0x1D00...0x1D7F, 0x1D80...0x1DBF,
            0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0x10780...0x107BF, 0x1DF00...0x1DFFF,
        ]
        let letters = blocks.joined().compactMap(Unicode.Scalar.init).filter { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return false
            }
        }
        // One letter a line, so no letter is spelled by the one after it.
        let spelled = letters.map(String.init).joined(separator: "\n").applyingTransform(StringTransform("Latin-ASCII"), reverse: false)?
            .components(separatedBy: "\n")
        guard let spelled, spelled.count == letters.count else { return [:] }
        var table: [Unicode.Scalar: String] = [:]
        for (letter, ascii) in zip(letters, spelled) where ascii != String(letter) && !ascii.isEmpty { table[letter] = ascii }
        return table
    }()

    /// A space, a line break or a tab: what `visible` removes, or keeps as one space.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return scalar == " " || (0x09...0x0D).contains(scalar.value) }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return scalar.properties.isWhitespace
        }
    }

    /// What doesn't show as a character of its own: format, control and default-ignorable characters, combining marks,
    /// the invisible ones `Address.isInvisible` names, U+FFFD and the blank Braille pattern U+2800.
    private static func isUnseen(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return scalar.value < 0x20 || scalar.value == 0x7F } // ASCII's control characters
        let properties = scalar.properties
        switch properties.generalCategory {
        case .format, .control, .nonspacingMark, .enclosingMark: return true
        default: break
        }
        return properties.isDefaultIgnorableCodePoint || Address.isInvisible(scalar) || scalar.value == 0xFFFD || scalar.value == 0x2800
    }

    /// Every letter `visible` reads as another: `lookAlikeLetters`, and the Latin letters with a stroke, bar or hook
    /// (`LookAlikeLetters.marked`), which are Latin letters of their own for display safety (`SymbolSafety`: ÐOGE and ØRE
    /// are fine symbols) but read as the letters they are drawn like.
    private static let readAs: [Unicode.Scalar: Unicode.Scalar] = {
        var map = lookAlikeLetters
        for (code, latin) in LookAlikeLetters.marked {
            if let scalar = Unicode.Scalar(code), map[scalar] == nil { map[scalar] = latin.unicodeScalars.first! }
        }
        return map
    }()

    /// Whether `text` is plain printable ASCII — letters, digits, punctuation and spaces — and not empty.
    public static func isPlain(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    /// U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069: they change the order text shows in.
    private static let bidiControls: Set<UInt32> = Set([0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069))

    /// Letters and digits of other scripts drawn like Latin ones, each with the letter it passes for: Unicode's
    /// confusables for every script (`LookAlikeLetters`, generated from UTS #39 data), with the few below kept as they
    /// were written here, case for case (Unicode reads a Cyrillic "І" or Greek "Ι" as "l", which `readings` "b" does
    /// anyway).
    static let lookAlikeLetters: [Unicode.Scalar: Unicode.Scalar] = {
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (code, latin) in LookAlikeLetters.confusables { if let scalar = Unicode.Scalar(code) { map[scalar] = latin.unicodeScalars.first! } }
        return map.merging(handLookAlikes) { _, kept in kept }
    }()

    /// Cyrillic and Greek letters drawn like Latin ones (Unicode's confusables, the unambiguous ones), case for case.
    private static let handLookAlikes: [Unicode.Scalar: Unicode.Scalar] = {
        let pairs: [(UInt32, Character)] = [
            // Cyrillic capitals, then small letters.
            (0x0410, "A"), (0x0412, "B"), (0x0415, "E"), (0x041A, "K"), (0x041C, "M"), (0x041D, "H"), (0x041E, "O"), (0x0420, "P"),
            (0x0421, "C"), (0x0422, "T"), (0x0425, "X"), (0x0423, "Y"), (0x04AE, "Y"), (0x0405, "S"), (0x0406, "I"), (0x0408, "J"), (0x0417, "3"),
            (0x0430, "a"), (0x0435, "e"), (0x043E, "o"), (0x0440, "p"), (0x0441, "c"), (0x0443, "y"), (0x0445, "x"), (0x0455, "s"),
            (0x0456, "i"), (0x0458, "j"), (0x04BB, "h"), (0x0501, "d"), (0x051B, "q"), (0x051D, "w"), (0x04AF, "y"),
            // Greek capitals, then small letters.
            (0x0391, "A"), (0x0392, "B"), (0x0395, "E"), (0x0396, "Z"), (0x0397, "H"), (0x0399, "I"), (0x039A, "K"), (0x039C, "M"),
            (0x039D, "N"), (0x039F, "O"), (0x03A1, "P"), (0x03A4, "T"), (0x03A5, "Y"), (0x03A7, "X"),
            (0x03BF, "o"), (0x03BD, "v"), (0x03C1, "p"), (0x03B9, "i"), (0x03C5, "u"), (0x03C7, "x"), (0x03B1, "a"),
            // Latin letters from other blocks: dotless i, small capital I, script g.
            (0x0131, "i"), (0x026A, "I"), (0x0261, "g"),
        ]
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (code, latin) in pairs { if let scalar = Unicode.Scalar(code) { map[scalar] = latin.unicodeScalars.first! } }
        return map
    }()

    /// Digits and letters drawn alike in most fonts: 0 as O; 1, I and | as l.
    private static let lookAlikeDigits: [Unicode.Scalar: Unicode.Scalar] = ["0": "O", "1": "l", "I": "l", "|": "l"]

    /// The curated dollar stables, by contract address. A token is one of them only by its address: anyone can deploy a
    /// token called "USDC".
    public static let dollarStables: Set<Address> = Set(Token.core.filter { ["USDC", "USDT0", "AUSD", "USDe", "USD1", "mUSD"].contains($0.symbol) }.map(\.address))

    /// `amount` in dollars when `token` is one of the curated dollar stables; nil for any other token, whatever its
    /// symbol.
    public static func stableUSD(_ token: Token, amount: BigUInt) -> Double? {
        dollarStables.contains(token.address) ? Amount.units(amount, decimals: token.decimals) : nil
    }

    /// `prices` with each of `tokens` that is a curated dollar stable (`dollarStables`, by address) and has no price at
    /// $1, as the price finder values USDC and AUSD: USDe, USD1 and mUSD have no pool it looks for, and each is a dollar.
    /// A stable a pool prices keeps that price.
    public static func stablesAtPar(_ prices: [Address: Double], tokens: [Token]) -> [Address: Double] {
        var out = prices
        for token in tokens where dollarStables.contains(token.address) && out[token.address] == nil { out[token.address] = 1 }
        return out
    }

    /// The curated tokens among `tokens`, MON included, with no usable price in `prices`, in `tokens` order: cbBTC, LBTC,
    /// ezETH, rETH and aprMON have no pool the price finder looks for, and any curated token's price read can fail on its
    /// own. Their value is missing, never $0.
    public static func unpricedCurated(_ tokens: [Token], prices: [Address: Double]) -> [Token] {
        tokens.filter { token in
            Token.core(token.address) != nil && !(prices[token.address].map { $0.isFinite && $0 > 0 } ?? false)
        }
    }

    /// `unpricedCurated`, split by why. `noPool`: those the price finder found no pool for (`PriceService.withoutPool`:
    /// cbBTC, LBTC, ezETH, rETH, aprMON), which simply have no price. A list names them and leaves them out of its total,
    /// and a send still starts on the top priced token, so holding any amount of one — a speck anyone can send included —
    /// changes nothing else. `unread`: those whose price read failed (MON's included), whose price is unknown. A list
    /// says so, shows no total and preselects nothing, as when the whole price read fails.
    public static func unpricedCurated(_ tokens: [Token], prices: [Address: Double], noPool: Set<Address>) -> (noPool: [Token], unread: [Token]) {
        let unpriced = unpricedCurated(tokens, prices: prices)
        return (unpriced.filter { noPool.contains($0.address) }, unpriced.filter { !noPool.contains($0.address) })
    }

    /// Symbols as a list in words, in the app's language as a whole: in English "cbBTC", "cbBTC and LBTC", "cbBTC, LBTC
    /// and rETH", as it has always read whatever the region; every other language joins them its own way
    /// (`ListFormatter`: "cbBTC, LBTC et rETH", "cbBTC、LBTC和rETH").
    public static func symbolList(_ tokens: [Token]) -> String {
        let symbols = tokens.map(\.symbol)
        guard let last = symbols.last else { return "" }
        guard symbols.count > 1 else { return last }
        let locale = L10n.locale
        if locale.language.languageCode == .english {
            // not localized: English as it has always read; ListFormatter would put a comma before "and" in the US
            return symbols.dropLast().joined(separator: ", ") + " and " + last
        }
        let list = ListFormatter()
        list.locale = locale
        return list.string(from: symbols) ?? symbols.joined(separator: ", ")
    }
}
