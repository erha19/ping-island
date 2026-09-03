import Foundation
import SwiftUI

@MainActor
enum AppLocalization {
    static func string(_ key: String) -> String {
        string(key, locale: AppSettings.shared.locale)
    }

    static func string(_ key: String, locale: Locale) -> String {
        String(
            localized: String.LocalizationValue(key),
            bundle: .main,
            locale: locale
        )
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments, locale: AppSettings.shared.locale)
    }

    static func format(_ key: String, _ arguments: CVarArg..., locale: Locale) -> String {
        format(key, arguments: arguments, locale: locale)
    }

    private static func format(_ key: String, arguments: [CVarArg], locale: Locale) -> String {
        let format = string(key, locale: locale)
        return String(format: format, locale: locale, arguments: arguments)
    }
}

struct AppLocalizedRootView<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.locale, settings.locale)
            .environment(
                \.islandExperienceTheme,
                ExperienceThemeRegistry.theme(
                    for: settings.experienceThemeID,
                    pixelPalette: settings.pixelThemePaletteID
                )
            )
    }
}

extension Text {
    init(appLocalized key: String) {
        self.init(LocalizedStringKey(key))
    }
}
