#if os(iOS)
import SwiftUI
#if !COCOAPODS
import BubblCore
#endif

/// Bubbl's notification screen: a card over the app, on a dimmed background, with the
/// notification's media, headline and body, its survey (a wizard, one question at a time) and its
/// call to action. The close button floats inside the card's top-right corner, 8 points in from
/// both edges. Laid out as Android's.
@available(iOS 17, *)
struct NotificationScreen: View {
    @ObservedObject var model: NotificationModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Look.scrim.ignoresSafeArea()
                ScrollView {
                    card
                        .frame(maxWidth: Look.cardMaxWidth)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .onAppear { model.appear() }
        .accessibilityAddTraits(.isModal)
    }

    private var notification: BubblNotification { model.notification }

    /// Audio plays from a row in the card; only a cover picture, if it has one, goes on top.
    private var mediaOnTop: BubblNotification.Media? {
        guard let media = notification.media else { return nil }
        return media.kind != .audio || media.pictureUrl != nil ? media : nil
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let media = mediaOnTop {
                MediaHeader(model: model, media: media)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(notification.headline)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Look.onSurface)
                    .padding(.trailing, mediaOnTop == nil ? 36 : 0)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.subheadline)
                        .foregroundStyle(Look.onSurfaceMuted)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let media = notification.media, media.kind == .audio, let url = media.url.flatMap(URL.init(string:)) {
                    AudioRow(model: model, url: url).padding(.top, 16)
                }
                if model.hasSurvey {
                    SurveyWizard(model: model)
                } else if let cta = notification.cta {
                    PrimaryButton(title: cta.label) { model.openCta() }
                        .padding(.top, 20)
                        .accessibilityIdentifier("bubbl.cta")
                }
            }
            // Below the ribbon when no media is there to carry it.
            .padding(.top, notification.sandbox && mediaOnTop == nil ? 18 : 0)
            .padding(Look.cardPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.surface)
        .clipShape(RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .overlay(alignment: .topTrailing) {
            CloseButton { model.dismiss() }.padding(8)
        }
        .overlay(alignment: .topLeading) {
            if notification.sandbox { SandboxRibbon().padding(8) }
        }
        // A container: an identifier on it alone would replace its children's (the close button's).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bubbl.card")
    }
}

// MARK: - The survey

/// The survey as steps: progress, one question, Back and Next (Send on the last). Answers live in
/// the model, so going back keeps them. Sending shows a thank-you step, with the campaign's call
/// to action if it has one.
@available(iOS 17, *)
struct SurveyWizard: View {
    @ObservedObject var model: NotificationModel

    var body: some View {
        if model.submitted {
            thanks
        } else {
            questions
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Words.progress(model.step + 1, of: model.questions.count))
                .font(.footnote)
                .foregroundStyle(Look.onSurfaceMuted)
            ProgressView(value: Double(model.step + 1), total: Double(max(model.questions.count, 1)))
                .tint(Look.accent)
                .padding(.top, 6)
                .accessibilityHidden(true)
            if let question = model.questions[safe: model.step] {
                QuestionView(model: model, question: question)
                    .id(question.id)
                    .padding(.top, 20)
            }
            if model.showingError {
                Text(Words.answerRequired)
                    .font(.subheadline)
                    .foregroundStyle(Look.error)
                    .padding(.top, 12)
                    .accessibilityIdentifier("bubbl.error")
            }
            HStack(spacing: 12) {
                // No Back on the first question: Next takes the whole row.
                if model.step > 0 {
                    SecondaryButton(title: Words.back) { model.back() }
                        .frame(width: 96)
                        .accessibilityIdentifier("bubbl.back")
                }
                PrimaryButton(title: model.isLastStep ? Words.submit : Words.next) { model.next() }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("bubbl.next")
            }
            .padding(.top, 20)
        }
        .padding(.top, 16)
    }

    private var thanks: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Words.thanks)
                .font(.headline)
                .foregroundStyle(Look.onSurface)
                .accessibilityIdentifier("bubbl.thanks")
            if let cta = model.notification.cta {
                PrimaryButton(title: cta.label) { model.openCta() }.padding(.top, 20)
                SecondaryButton(title: Words.done) { model.finish() }.padding(.top, 4)
            } else {
                PrimaryButton(title: Words.done) { model.finish() }.padding(.top, 20)
            }
        }
        .padding(.top, 20)
    }
}

/// One question, by its kind.
@available(iOS 17, *)
struct QuestionView: View {
    @ObservedObject var model: NotificationModel
    let question: BubblNotification.Question

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.text + (question.required ? " *" : ""))
                .font(.body.weight(.semibold))
                .foregroundStyle(Look.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            input
        }
    }

    @ViewBuilder
    private var input: some View {
        switch question.kind {
        case .openEnded:
            TextField(Words.answerHint, text: typed { model.form.setText(question, $0) }, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("bubbl.answer")
        case .number:
            TextField(Words.numberHint, text: typed { model.form.setNumber(question, $0) })
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("bubbl.answer")
        case .singleChoice:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(question.choices, id: \.id) { choice in
                    ChoiceRow(title: choice.text, selected: model.form.answer(question.id) == .string(choice.id), multiple: false) {
                        model.form.setChoice(question, choice.id)
                        model.answered()
                    }
                }
            }
        case .multipleChoice:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(question.choices, id: \.id) { choice in
                    let chosen = chosenIds.contains(choice.id)
                    ChoiceRow(title: choice.text, selected: chosen, multiple: true) {
                        model.form.toggleChoice(question, choice.id, chosen: !chosen)
                        model.answered()
                    }
                }
            }
        case .boolean:
            HStack(spacing: 12) {
                ForEach([true, false], id: \.self) { value in
                    ChoiceRow(title: value ? Words.yes : Words.no, selected: model.form.answer(question.id) == .bool(value), multiple: false) {
                        model.form.setBoolean(question, value)
                        model.answered()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .rating:
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        model.form.setRating(question, value)
                        model.answered()
                    } label: {
                        Image(systemName: "star.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(value <= rating ? Look.accent : Look.outline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Words.ratingStar(value))
                    .accessibilityAddTraits(value == rating ? .isSelected : [])
                }
            }
        case .slider:
            AnswerSlider(
                value: model.form.answer(question.id)?.number,
                range: SurveyForm.sliderMin...SurveyForm.sliderMax,
                step: SurveyForm.sliderStep,
                label: question.text
            ) { value in
                model.form.setSlider(question, value)
                model.answered()
            }
        }
    }

    private var chosenIds: [String] {
        if case .array(let values)? = model.form.answer(question.id) { return values.compactMap(\.stringValue) }
        return []
    }

    private var rating: Int {
        model.form.answer(question.id)?.number.map { Int($0) } ?? 0
    }

    /// Text as typed, kept in the model (so going back keeps it); the form gets it tidied.
    private func typed(_ apply: @escaping (String) -> Void) -> Binding<String> {
        Binding(
            get: { model.typed[question.id] ?? "" },
            set: { text in
                model.typed[question.id] = text
                apply(text)
                model.answered()
            }
        )
    }
}

/// A choice: a radio button (one of several) or a checkbox (any of several), 48 points tall.
@available(iOS 17, *)
struct ChoiceRow: View {
    let title: String
    let selected: Bool
    let multiple: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: multiple ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.title3)
                    .foregroundStyle(selected ? Look.accent : Look.onSurfaceMuted)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Look.onSurface)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The slider question: no handle until it's touched (a handle already placed would look like an
/// answer), then whole and half steps across the range, with the value shown under it.
@available(iOS 17, *)
struct AnswerSlider: View {
    let value: Double?
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let width = max(proxy.size.width - 28, 1)
                let fraction = value.map { ($0 - range.lowerBound) / (range.upperBound - range.lowerBound) } ?? 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Look.outline).frame(height: 4).padding(.horizontal, 14)
                    Capsule().fill(Look.accent).frame(width: value == nil ? 0 : width * fraction, height: 4).padding(.leading, 14)
                    if value != nil {
                        Circle().fill(Look.accent).frame(width: 28, height: 28).offset(x: width * fraction)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let x = min(max(drag.location.x - 14, 0), width)
                    let raw = range.lowerBound + Double(x / width) * (range.upperBound - range.lowerBound)
                    onChange((raw / step).rounded() * step)
                })
            }
            .frame(height: 48)
            Text(value.map(Self.format) ?? Words.sliderUnanswered)
                .font(.subheadline)
                .foregroundStyle(Look.onSurfaceMuted)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(value.map(Self.format) ?? Words.sliderUnanswered)
        .accessibilityAdjustableAction { direction in
            let current = value ?? range.lowerBound
            switch direction {
            case .increment: onChange(min(current + step, range.upperBound))
            case .decrement: onChange(max(current - step, range.lowerBound))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("bubbl.slider")
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

// MARK: - Buttons

@available(iOS 17, *)
struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Look.onAccent)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Look.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

@available(iOS 17, *)
struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Look.accent)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The ✕ that floats in the card's top-right corner, over any media.
@available(iOS 17, *)
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Look.onSurface)
                .frame(width: 36, height: 36)
                .background(Look.surface, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Words.close)
        .accessibilityIdentifier("bubbl.close")
    }
}

/// The SANDBOX mark on a notification from a Sandbox workspace, in the card's top-left corner (the
/// close button has the right): so nobody mistakes a test for the real thing. Not themeable.
@available(iOS 17, *)
struct SandboxRibbon: View {
    var body: some View {
        Text("SANDBOX")
            .font(.system(size: 11, weight: .heavy))
            .tracking(1)
            .foregroundStyle(Color(red: 0.23, green: 0.15, blue: 0))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(red: 0.98, green: 0.72, blue: 0.13), in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .accessibilityLabel("Sandbox")
            .accessibilityIdentifier("bubbl.sandbox")
    }
}
#endif
