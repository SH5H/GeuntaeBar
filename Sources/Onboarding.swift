import Combine
import Foundation

@MainActor
final class OnboardingState: ObservableObject {
    enum Destination: String {
        case onboarding, signIn
    }

    @Published private(set) var step = 0
    @Published private(set) var isPresented = false
    let stepCount = 6
    private let defaults: UserDefaults
    private var didLaunch = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isLastStep: Bool { step == stepCount - 1 }
    var isSignInStep: Bool { step == 1 }

    func launch(hasSavedSession: Bool) -> Destination? {
        guard !didLaunch else { return nil }
        didLaunch = true
        if !defaults.bool(forKey: "hasSeenOnboarding") {
            show()
            return .onboarding
        }
        return sessionChanged(hasSavedSession: hasSavedSession)
    }

    func show() {
        step = 0
        isPresented = true
    }

    func previous() {
        if step > 0 { step -= 1 }
    }

    func next(isSignedIn: Bool) {
        guard isPresented else { return }
        guard !isSignInStep || isSignedIn else { return }
        if !isLastStep { step += 1 }
    }

    func showSignIn() {
        step = 1
    }

    func skipSignIn() {
        if isPresented && isSignInStep { step += 1 }
    }

    func requestSignIn() -> Destination {
        if isPresented {
            showSignIn()
            return .onboarding
        }
        return .signIn
    }

    func close() {
        isPresented = false
    }

    func finish() {
        guard isPresented && isLastStep else { return }
        defaults.set(true, forKey: "hasSeenOnboarding")
        close()
    }

    func sessionChanged(hasSavedSession: Bool) -> Destination? {
        !hasSavedSession && !isPresented ? .signIn : nil
    }
}
