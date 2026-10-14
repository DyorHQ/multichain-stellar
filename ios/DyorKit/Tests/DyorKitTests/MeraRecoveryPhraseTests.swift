import XCTest
@testable import DyorKit

/// Export for a passkey account (MERA-PLAN §7): the words shown are the account output's BIP-39 phrase and only when
/// they derive the account on screen, and the three-word check before "Done".
final class MeraRecoveryPhraseTests: XCTestCase {
    /// The vector in MeraTests, from `@category-labs/mera` 0.2.0.
    let prf = Data(hex: "0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!
    let account = Address("0xF9297b542BDb5DA50C364f9AE4Cbe1F3933bA40F")!
    let phrase = "abandon amount liar amount expire adjust cage candy arch gather drum bullet absurd math era live bid rhythm alien crouch range attend journey unaware"

    /// A seeded generator, so a quiz is reproducible.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Words

    func testWordsAreTheAccountOutputsPhrase() throws {
        let words = try XCTUnwrap(Mera.RecoveryPhrase.words(prf: prf, account: account))
        XCTAssertEqual(words.count, 24)
        XCTAssertEqual(words.joined(separator: " "), phrase)
        XCTAssertEqual(words.joined(separator: " "), Mera.mnemonic(entropy: prf))
        // What is shown restores the same wallet in any BIP-39 wallet.
        XCTAssertEqual(WalletImport.account(fromMnemonic: words.joined(separator: " "))?.address, account)
    }

    func testNoWordsForAnotherAccountOrAMalformedOutput() {
        let other = Mera.evmAccount(prf: prf, index: 1)!.address
        XCTAssertNil(Mera.RecoveryPhrase.words(prf: prf, account: other), "never shown for an account the phrase doesn't derive")
        XCTAssertNil(Mera.RecoveryPhrase.words(prf: Data(repeating: 0xB2, count: 32), account: account), "another passkey's output")
        XCTAssertNil(Mera.RecoveryPhrase.words(prf: prf.prefix(31), account: account))
        XCTAssertNil(Mera.RecoveryPhrase.words(prf: prf.prefix(16), account: account), "a 12-word output is not a Mera account")
    }

    func testVisibleForAMinute() {
        XCTAssertEqual(Mera.RecoveryPhrase.visibleFor, 60)
        XCTAssertEqual(Mera.RecoveryPhrase.wordCount, 24)
    }

    // MARK: Quiz

    func testQuizAsksThreeDistinctWordsInOrderWithTheirWordAmongDecoys() throws {
        let words = phrase.split(separator: " ").map(String.init)
        for seed in UInt64(0)..<300 {
            var generator = SplitMix64(state: seed)
            let quiz = try XCTUnwrap(Mera.RecoveryPhrase.Quiz(words: words, using: &generator))
            let numbers = quiz.questions.map(\.number)
            XCTAssertEqual(numbers.count, 3)
            XCTAssertEqual(Set(numbers).count, 3, "three different positions")
            XCTAssertEqual(numbers, numbers.sorted(), "asked in phrase order")
            for question in quiz.questions {
                XCTAssertTrue((1...24).contains(question.number))
                XCTAssertEqual(question.choices.count, 4)
                XCTAssertEqual(Set(question.choices).count, 4, "no repeated choice, even for a word the phrase repeats")
                XCTAssertEqual(question.answer, words[question.number - 1])
                XCTAssertTrue(question.choices.contains(words[question.number - 1]))
                XCTAssertTrue(question.choices.allSatisfy { BIP39Wordlist.index(of: $0) != nil }, "decoys are BIP-39 words")
            }
        }
    }

    func testQuizPassesOnlyWithEveryAnswerRight() throws {
        let words = phrase.split(separator: " ").map(String.init)
        var generator = SplitMix64(state: 7)
        let quiz = try XCTUnwrap(Mera.RecoveryPhrase.Quiz(words: words, using: &generator))
        let right = Dictionary(uniqueKeysWithValues: quiz.questions.map { ($0.number, words[$0.number - 1]) })
        XCTAssertTrue(quiz.passes(right))

        for question in quiz.questions {
            var missing = right
            missing[question.number] = nil
            XCTAssertFalse(quiz.passes(missing), "every question needs an answer")
            for decoy in question.choices where decoy != words[question.number - 1] {
                var wrong = right
                wrong[question.number] = decoy
                XCTAssertFalse(quiz.passes(wrong))
            }
        }
        XCTAssertFalse(quiz.passes([:]))
        // Picks for positions that weren't asked don't count.
        let unasked = Set(1...24).subtracting(right.keys).first!
        XCTAssertTrue(quiz.passes(right.merging([unasked: "zoo"]) { $1 }))
    }

    func testQuizIsReproducibleWithTheSameGenerator() {
        let words = phrase.split(separator: " ").map(String.init)
        var a = SplitMix64(state: 42), b = SplitMix64(state: 42), c = SplitMix64(state: 43)
        let first = Mera.RecoveryPhrase.Quiz(words: words, using: &a)
        XCTAssertEqual(first, Mera.RecoveryPhrase.Quiz(words: words, using: &b))
        XCTAssertNotEqual(first, Mera.RecoveryPhrase.Quiz(words: words, using: &c))
    }

    func testQuizNeedsEnoughWordsAndChoices() {
        let words = phrase.split(separator: " ").map(String.init)
        XCTAssertNil(Mera.RecoveryPhrase.Quiz(words: Array(words.prefix(2))))
        XCTAssertNil(Mera.RecoveryPhrase.Quiz(words: words, count: 0))
        XCTAssertNil(Mera.RecoveryPhrase.Quiz(words: words, choices: 1))
        XCTAssertNil(Mera.RecoveryPhrase.Quiz(words: words, choices: 2049))
        XCTAssertEqual(Mera.RecoveryPhrase.Quiz(words: words, count: 24)?.questions.map(\.number), Array(1...24))
    }
}
