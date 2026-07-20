//
//  LanguageOption.swift
//  OffGrid
//
import Foundation

struct LanguageOption: Identifiable, Hashable {
    let id: String        // ISO 639-1 code, or "auto"
    let displayName: String

    static let autoDetect = LanguageOption(id: "auto", displayName: "Auto-Detect")

    static let all: [LanguageOption] = [
        .autoDetect,
        LanguageOption(id: "en", displayName: "English"),
        LanguageOption(id: "zh", displayName: "Mandarin Chinese"),
        LanguageOption(id: "hi", displayName: "Hindi"),
        LanguageOption(id: "es", displayName: "Spanish"),
        LanguageOption(id: "fr", displayName: "French"),
        LanguageOption(id: "ar", displayName: "Standard Arabic"),
        LanguageOption(id: "pt", displayName: "Portuguese"),
        LanguageOption(id: "bn", displayName: "Bengali"),
        LanguageOption(id: "ru", displayName: "Russian"),
        LanguageOption(id: "ur", displayName: "Urdu"),
        LanguageOption(id: "ja", displayName: "Japanese"),
        LanguageOption(id: "ko", displayName: "Korean"),
        LanguageOption(id: "te", displayName: "Telugu"),
        LanguageOption(id: "ta", displayName: "Tamil"),
    ]

    /// Whisper reports back a bare ISO code after auto-detection; this
    /// resolves it to the same display name used in the picker so the
    /// "Detected Language: [Name]" badge stays consistent with the list.
    static func displayName(forCode code: String) -> String {
        all.first(where: { $0.id == code })?.displayName ?? code.uppercased()
    }
}
