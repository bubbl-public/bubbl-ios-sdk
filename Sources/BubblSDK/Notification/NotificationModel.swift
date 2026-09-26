#if os(iOS)
import SwiftUI
import UIKit
#if !COCOAPODS
import BubblCore
#endif

/// One notification on Bubbl's screen: what the person has done with it, the survey's answers and
/// step, and the events that go with it (as Android's NotificationActivity): displayed (or opened,
/// from a tapped notification) once it's up, survey started and submitted, CTA clicks, media
/// viewed and completed, and dismissed when it's closed any other way.
@available(iOS 17, *)
@MainActor
final class NotificationModel: ObservableObject {
    let notification: BubblNotification
    let opened: Bool

    @Published var form: SurveyForm
    /// What's typed in each open-ended or number question, as typed (the form keeps it tidied).
    @Published var typed: [String: String] = [:]
    @Published private(set) var step = 0
    @Published private(set) var showingError = false
    @Published private(set) var submitted = false

    /// Closed by answering, a CTA or a media link: anything else counts as dismissing it.
    private var acted = false
    private var surveyStarted = false
    private var appeared = false
    private let events: NotificationEvents?
    private let close: @MainActor () -> Void

    init(notification: BubblNotification, opened: Bool, events: NotificationEvents?, close: @escaping @MainActor () -> Void) {
        self.notification = notification
        self.opened = opened
        self.events = events
        self.close = close
        form = SurveyForm(notification.questions)
    }

    var questions: [BubblNotification.Question] { form.questions }
    var hasSurvey: Bool { notification.isSurvey && !questions.isEmpty }
    var isLastStep: Bool { step == questions.count - 1 }

    // MARK: - The screen

    func appear() {
        guard !appeared else { return }
        appeared = true
        let notification = notification
        if opened {
            record { try await $0.opened(notification) }
        } else {
            record { try await $0.displayed(notification) }
        }
    }

    /// The close button.
    func dismiss() {
        if !acted {
            let notification = notification
            record { try await $0.dismissed(notification) }
        }
        close()
    }

    func openCta() {
        guard let cta = notification.cta else { return }
        acted = true
        let notification = notification
        record { try await $0.ctaClicked(notification) }
        open(cta.url)
        close()
    }

    // MARK: - Media

    /// An image shown, or a video, YouTube video or audio started.
    func mediaViewed() {
        let notification = notification
        record { try await $0.mediaViewed(notification, positionSeconds: 0) }
    }

    func mediaCompleted(seconds: Double) {
        let notification = notification
        record { try await $0.mediaCompleted(notification, positionSeconds: seconds.isFinite ? seconds : 0) }
    }

    /// Media of a kind the card can't play (a PDF, a file): opened outside.
    func openMedia(_ url: String) {
        acted = true
        mediaViewed()
        open(url)
    }

    // MARK: - The survey, one question at a time

    /// Any answer given: the first means the survey has been started.
    func answered() {
        if !surveyStarted {
            surveyStarted = true
            let notification = notification
            record { try await $0.surveyStarted(notification) }
        }
        if let question = questions[safe: step], form.answer(question.id) != nil { showingError = false }
    }

    func next() {
        guard let question = questions[safe: step] else { return }
        if question.required && form.answer(question.id) == nil {
            showingError = true
            return
        }
        if isLastStep { submit() } else { go(to: step + 1) }
    }

    func back() {
        go(to: step - 1)
    }

    private func go(to index: Int) {
        step = min(max(index, 0), max(questions.count - 1, 0))
        showingError = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func submit() {
        // Each step checked its own question; this catches a required one skipped by Back.
        if let missing = form.missing.first, let index = questions.firstIndex(of: missing) {
            go(to: index)
            showingError = true
            return
        }
        acted = true
        let notification = notification
        let answers = form
        record { try await $0.surveySubmitted(notification, answers) }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        submitted = true
    }

    /// Done, from the thank-you step.
    func finish() {
        close()
    }

    // MARK: - Helpers

    private func open(_ link: String) {
        guard LinkPolicy.canOpen(link), let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    /// Records an event on the engine's side, so closing the screen doesn't lose it, then sends
    /// the queue.
    private func record(_ body: @escaping @Sendable (NotificationEvents) async throws -> Void) {
        guard let events else { return }
        Task {
            do {
                try await body(events)
                EngineHost.shared.submit("events") { await $0.flushEvents() }
            } catch {
                BubblLog.debug("A notification event wasn't recorded (\(type(of: error)))")
            }
        }
    }
}

@available(iOS 17, *)
extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
