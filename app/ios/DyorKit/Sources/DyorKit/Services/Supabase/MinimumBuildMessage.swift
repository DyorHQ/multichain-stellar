import Foundation

extension MinimumBuild {
    /// The owner's message for the Update screen while the app is in `language`. The row's text is written in English, so
    /// it is shown only while the app is in English; in any other language, and when the row has none, this is nil and
    /// the screen says it in the app's own text, in the app's language.
    public func ownerMessage(in language: AppLanguage) -> String? {
        language == .en && !message.isEmpty ? message : nil
    }
}
