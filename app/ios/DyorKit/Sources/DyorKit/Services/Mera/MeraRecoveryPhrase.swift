import Foundation

/* Export for a passkey account (MERA-PLAN §7): the 24-word BIP-39 recovery phrase of the passkey's account output,
   which restores the wallet in any BIP-39 wallet without the passkey. The app's MeraSession reveals it behind a fresh
   pinned ceremony every time and never stores it; this half is what `swift test` can pin: which words are shown (only
   ones that derive the account on screen), how long they stay up, and the three-word check before "Done". */
extension Mera {
    public enum RecoveryPhrase {
        /// A 32-byte PRF output encodes to 24 words.
        public static let wordCount = 24
        /// How long the words stay on screen after a reveal before they hide themselves.
        public static let visibleFor: TimeInterval = 60

        /// The words for a passkey's account output, only when the phrase itself derives `account` at
        /// m/44'/60'/0'/0/0, the path MetaMask, Rabby and OKX restore it on: what is shown is exactly what brings this
        /// wallet back. Nil for a malformed output or one that derives another account.
        public static func words(prf: Data, account: Address) -> [String]? {
            guard prf.count == 32, let phrase = Mnemonic.phrase(fromEntropy: prf),
                  WalletImport.account(fromMnemonic: phrase)?.address == account else { return nil }
            let words = Mnemonic.words(phrase)
            return words.count == wordCount ? words : nil
        }

        /// The check before "Done": `count` random positions of the phrase, each with its word among random BIP-39
        /// decoys. It keeps only the asked words, so the rest of the phrase can be dropped the moment it hides. A wrong
        /// answer means reading the phrase again (a new reveal), so the choices can't be guessed through.
        public struct Quiz: Equatable, Sendable {
            public struct Question: Equatable, Sendable, Identifiable {
                /// The word's number as the phrase shows it, from 1.
                public let number: Int
                /// The word among the decoys, shuffled; all different.
                public let choices: [String]
                let answer: String
                public var id: Int { number }
            }

            /// In phrase order.
            public let questions: [Question]

            /// Nil when the phrase is too short for `count` questions or a question can't have `choices` options.
            public init?<G: RandomNumberGenerator>(words: [String], count: Int = 3, choices: Int = 4, using generator: inout G) {
                let list = BIP39Wordlist.words
                guard count >= 1, words.count >= count, (2...list.count).contains(choices) else { return nil }
                let positions = Array((0..<words.count).shuffled(using: &generator).prefix(count)).sorted()
                questions = positions.map { position in
                    let answer = words[position]
                    var options = [answer]
                    while options.count < choices {
                        let decoy = list[Int.random(in: 0..<list.count, using: &generator)]
                        if !options.contains(decoy) { options.append(decoy) }
                    }
                    return Question(number: position + 1, choices: options.shuffled(using: &generator), answer: answer)
                }
            }

            public init?(words: [String], count: Int = 3, choices: Int = 4) {
                var generator = SystemRandomNumberGenerator()
                self.init(words: words, count: count, choices: choices, using: &generator)
            }

            /// Whether `picks` (question number → the word picked) answers every question right. A missing pick fails.
            public func passes(_ picks: [Int: String]) -> Bool {
                questions.allSatisfy { picks[$0.number] == $0.answer }
            }
        }
    }
}
