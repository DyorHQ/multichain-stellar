import CoreText
import Foundation
import XCTest
@testable import DyorKit

/// The "Continue with Google" label's font (`GoogleButtonFont`): Google Sans only when the bundled subset can draw every
/// character of the label, so a translated label never shows a missing glyph; never in Chinese or Korean.
final class GoogleButtonFontTests: XCTestCase {
    /// The characters the bundled font file draws, read from its character map.
    private static func fontCharacters() throws -> Set<Character> {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        let file = ios.appendingPathComponent("DyorHQ/Resources/Fonts/GoogleSans-Medium.ttf")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor])
        let font = CTFontCreateWithFontDescriptor(try XCTUnwrap(descriptors.first), 17, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "GoogleSans-Medium", "the name the app asks for")
        let characters = CTFontCopyCharacterSet(font) as CharacterSet
        return Set((0x20...0x2FF).compactMap(Unicode.Scalar.init).filter(characters.contains).map(Character.init))
    }

    func testTheSubsetIsTheFontFile() throws {
        XCTAssertEqual(try Self.fontCharacters(), GoogleButtonFont.subsetCharacters, "update subsetCharacters with the font")
        XCTAssertTrue("Continue with Google".allSatisfy(GoogleButtonFont.subsetCharacters.contains), "the English label")
        // The subset has no Latin accents, which Spanish and French need.
        for accented in "éèêàçñüôáíóú…’" { XCTAssertFalse(GoogleButtonFont.subsetCharacters.contains(accented), "\(accented)") }
    }

    /// The font's licence lets the app bundle and subset it: the SIL Open Font License, with no reserved font name that a
    /// modified version would have to drop.
    func testTheFontsLicenceAllowsTheSubset() throws {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() }
        let file = ios.appendingPathComponent("DyorHQ/Resources/Fonts/GoogleSans-OFL.txt")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let licence = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(licence.contains("SIL Open Font License, Version 1.1"))
        let notice = try XCTUnwrap(licence.components(separatedBy: "\n").first)
        XCTAssertTrue(notice.hasPrefix("Copyright 2025 The Google Sans Project Authors"), notice)
        XCTAssertFalse(notice.contains("Reserved Font Name"), "a reserved name would bar a modified version from it")
    }

    func testGoogleSansOnlyForALabelTheSubsetDraws() {
        XCTAssertTrue(GoogleButtonFont.usesGoogleSans("Continue with Google", language: .en))
        XCTAssertTrue(GoogleButtonFont.usesGoogleSans("Continue with Google", language: .es), "a label the catalog leaves in English")
        XCTAssertFalse(GoogleButtonFont.usesGoogleSans("Continuar con Google", language: .es), "letters the subset lacks")
        XCTAssertFalse(GoogleButtonFont.usesGoogleSans("Continuer avec Google", language: .fr))
        XCTAssertFalse(GoogleButtonFont.usesGoogleSans("Se connecter à Google", language: .fr), "an accent")
        XCTAssertFalse(GoogleButtonFont.usesGoogleSans("通过 Google 继续", language: .zhHans))
        XCTAssertFalse(GoogleButtonFont.usesGoogleSans("Google 계정으로 계속하기", language: .ko))
        XCTAssertFalse(GoogleButtonFont.usesGoogleSans("Continue with Google", language: .ko), "Korean always uses the system font")
        XCTAssertFalse(GoogleButtonFont.usesGoogleSans("Continue with Google", language: .zhHans))
        XCTAssertFalse(GoogleButtonFont.usesGoogleSans("", language: .en))
    }
}
