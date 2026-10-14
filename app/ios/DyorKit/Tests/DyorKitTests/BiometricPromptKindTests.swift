import Foundation
import LocalAuthentication
import XCTest
@testable import DyorKit

/// App Lock's and the passkey's prompt (`BiometricGate` in the app's Theme.swift): its kind (`BiometricPromptKind`) names
/// it and picks its icon, so the icon never depends on text that is translated, and the reason iOS shows is written in
/// the code and resolved in the app's language.
final class BiometricPromptKindTests: XCTestCase {
    private static func source(_ path: String) throws -> String {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        guard FileManager.default.fileExists(atPath: ios.appendingPathComponent("DyorHQ").path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return try String(contentsOf: ios.appendingPathComponent(path), encoding: .utf8)
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// `BiometricGate`'s body in Theme.swift, its whitespace squeezed.
    private static func gate() throws -> String {
        let theme = try source("DyorHQ/Design/Theme.swift")
        let from = try XCTUnwrap(theme.range(of: "enum BiometricGate {")).upperBound
        let to = try XCTUnwrap(theme.range(of: "final class BiometricPrompt")).lowerBound
        return squeezed(String(theme[from..<to]))
    }

    /// The prompt's kind decides both its name and its icon; Apple's names are never translated.
    func testPromptKind() {
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: true, biometry: .faceID), .faceID)
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: true, biometry: .touchID), .touchID)
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: true, biometry: .opticID), .opticID)
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: true, biometry: .none), .passcode)
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: false, biometry: .faceID), .passcode, "no enrolled biometrics: the passcode")
        XCTAssertEqual(BiometricPromptKind.allCases.map(\.symbol), ["faceid", "touchid", "opticid", "lock"])
        XCTAssertEqual([BiometricPromptKind.faceID, .touchID, .opticID].map(\.name), ["Face ID", "Touch ID", "Optic ID"])
        XCTAssertEqual(BiometricPromptKind.passcode.name, "Passcode")
    }

    /// App Lock's and the passkey's prompt icon comes from the kind, never from the (translated) name; the reason iOS
    /// shows is written in the code and resolved in the app's language.
    func testTheGateIconNeverDependsOnTranslatedText() throws {
        let gate = try Self.gate()
        XCTAssertTrue(gate.contains("typealias PromptKind = BiometricPromptKind"))
        XCTAssertTrue(gate.contains("static var promptName: String { promptKind.name }"))
        XCTAssertTrue(gate.contains("static var promptSymbol: String { promptKind.symbol }"))
        XCTAssertFalse(gate.contains("switch promptName"))
        XCTAssertFalse(gate.contains("case \"Face ID\""))
        XCTAssertTrue(gate.contains("static func authenticate(reason: LocalizedStringResource) async -> Bool { await authenticate(reason: tr(reason)) }"))
        XCTAssertTrue(gate.contains("localizedReason: reason"))
        XCTAssertTrue(gate.contains("return kind == .passcode ? tr(\"Biometrics\") : kind.name"))
    }

    /// A reason that is already in the app's language (`tr("Confirm bridge")`, as the Bridge's own conversion writes it)
    /// has an overload of its own that shows it as it is and never looks it up again. That overload is generic and
    /// disfavoured, so a reason written as a literal still takes the `LocalizedStringResource` overload and becomes a
    /// key. A plain `String` overload would not do: even disfavoured, it takes every literal (the stand-in's second
    /// half shows it), and every App Lock prompt would be in English.
    func testATranslatedReasonIsShownAsItIs() throws {
        let gate = try Self.gate()
        let signature = "static func authenticate<S: StringProtocol>(reason verbatim: S) async -> Bool {"
        XCTAssertTrue(gate.contains("@MainActor @_disfavoredOverload " + signature))
        XCTAssertNil(gate.range(of: #"authenticate\(reason( \w+)?: String\)"#, options: .regularExpression), "a plain String overload takes every literal")
        let plain = try XCTUnwrap(gate.range(of: signature))
        let end = try XCTUnwrap(gate.range(of: "/// Whether an `authenticate` prompt is on screen", range: plain.upperBound..<gate.endIndex)).lowerBound
        let body = gate[plain.upperBound..<end]
        XCTAssertFalse(body.contains("tr("), "a translated reason is never looked up again")
        XCTAssertTrue(body.contains("let reason = String(verbatim)"))
        XCTAssertTrue(body.contains("localizedReason: reason"))

        let title = "Swap"
        XCTAssertEqual(Gate.authenticate(reason: "Confirm bridge"), .resource)
        XCTAssertEqual(Gate.authenticate(reason: "Confirm \(title)"), .resource)
        XCTAssertEqual(Gate.authenticate(reason: L10n.tr("Confirm bridge")), .text)
        XCTAssertEqual(PlainGate.authenticate(reason: "Confirm bridge"), .text, "a plain String overload takes the literal")
        XCTAssertEqual(PlainGate.authenticate(reason: "Confirm \(title)"), .text)
    }

    enum Taken { case resource, text }

    /// A stand-in with `BiometricGate.authenticate`'s two overloads, for the rule the gate relies on: a literal, with
    /// interpolations or without, takes the resource; a `String` takes the generic, disfavoured overload.
    private enum Gate {
        static func authenticate(reason: LocalizedStringResource) -> Taken { .resource }
        @_disfavoredOverload
        static func authenticate<S: StringProtocol>(reason text: S) -> Taken { .text }
    }

    /// The same with a plain `String` overload: the compiler prefers a literal's default type over the disfavouring.
    private enum PlainGate {
        static func authenticate(reason: LocalizedStringResource) -> Taken { .resource }
        @_disfavoredOverload
        static func authenticate(reason text: String) -> Taken { .text }
    }
}
