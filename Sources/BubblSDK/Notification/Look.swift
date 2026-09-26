#if os(iOS)
import SwiftUI
import UIKit

/// The notification screen's look. An app changes any colour with a colour set of the same name
/// in its asset catalogue (bubbl_accent, bubbl_surface…), light and dark, as Android's bubbl_
/// colour resources; the defaults follow the system's light and dark appearance.
@available(iOS 17, *)
enum Look {
    static let scrim = color("bubbl_scrim", light: 0x000000, 0.60, dark: 0x000000, 0.70)
    static let surface = color("bubbl_surface", light: 0xFFFFFF, dark: 0x1D2027)
    static let onSurface = color("bubbl_on_surface", light: 0x16181D, dark: 0xF1F2F5)
    static let onSurfaceMuted = color("bubbl_on_surface_muted", light: 0x5F6570, dark: 0xA9AEB8)
    static let outline = color("bubbl_outline", light: 0xD9DCE1, dark: 0x3A3F4A)
    static let accent = color("bubbl_accent", light: 0x3E4BDB, dark: 0x8C95FF)
    static let onAccent = color("bubbl_on_accent", light: 0xFFFFFF, dark: 0x10123A)
    static let error = color("bubbl_error", light: 0xC62828, dark: 0xFF8A80)
    static let mediaSurface = color("bubbl_media_surface", light: 0xF1F2F5, dark: 0x2A2E37)

    static let cardMaxWidth: CGFloat = 480
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 20
    static let mediaMaxHeight: CGFloat = 240

    private static func color(_ name: String, light: UInt32, _ lightAlpha: CGFloat = 1, dark: UInt32, _ darkAlpha: CGFloat = 1) -> Color {
        if let custom = UIColor(named: name, in: .main, compatibleWith: nil) { return Color(uiColor: custom) }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// The notification screen's words, in English unless the app gives its own: a Bubbl.strings
/// table in the app (keys as Android's strings: bubbl_close, bubbl_next…), translated the usual way.
@available(iOS 17, *)
enum Words {
    static func text(_ key: String, _ english: String) -> String {
        Bundle.main.localizedString(forKey: key, value: english, table: "Bubbl")
    }

    static var close: String { text("bubbl_close", "Close") }
    static var submit: String { text("bubbl_submit", "Send answers") }
    static var thanks: String { text("bubbl_thanks", "Thanks for your answers") }
    static var answerRequired: String { text("bubbl_answer_required", "Please answer this question to carry on") }
    static var next: String { text("bubbl_next", "Next") }
    static var back: String { text("bubbl_back", "Back") }
    static var done: String { text("bubbl_done", "Done") }
    static var yes: String { text("bubbl_yes", "Yes") }
    static var no: String { text("bubbl_no", "No") }
    static var answerHint: String { text("bubbl_answer_hint", "Your answer") }
    static var numberHint: String { text("bubbl_number_hint", "A number") }
    static var sliderUnanswered: String { text("bubbl_slider_unanswered", "Drag to answer") }
    static var play: String { text("bubbl_play_media", "Play") }
    static var pause: String { text("bubbl_pause_media", "Pause") }
    static var open: String { text("bubbl_open_media", "Open") }

    static func progress(_ step: Int, of total: Int) -> String {
        String(format: text("bubbl_question_progress", "Question %1$d of %2$d"), step, total)
    }

    static func ratingStar(_ value: Int) -> String {
        String(format: text("bubbl_rating_star", "%1$d of 5"), value)
    }

    static func mediaDescription(_ headline: String) -> String {
        String(format: text("bubbl_media_description", "Image for %1$@"), headline)
    }
}
#endif
