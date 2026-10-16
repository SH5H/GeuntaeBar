import Foundation

@main
struct OnboardingTests {
    @MainActor
    static func main() {
        let suite = "ai.wantedspace.WorkBar.OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstRun = OnboardingState(defaults: defaults)
        precondition(firstRun.launch(hasSavedSession: false) == .onboarding)
        precondition(firstRun.isPresented && firstRun.step == 0)
        precondition(firstRun.launch(hasSavedSession: false) == nil)
        precondition(firstRun.sessionChanged(hasSavedSession: false) == nil)
        firstRun.finish()
        precondition(firstRun.isPresented && !defaults.bool(forKey: "hasSeenOnboarding"))
        firstRun.previous()
        precondition(firstRun.step == 0)
        firstRun.next(isSignedIn: false)
        precondition(firstRun.isSignInStep)
        // Missing, failed, or unverified login must stay inside the wizard.
        firstRun.next(isSignedIn: false)
        precondition(firstRun.isSignInStep)
        precondition(firstRun.sessionChanged(hasSavedSession: false) == nil)
        firstRun.previous()
        precondition(firstRun.step == 0)
        precondition(firstRun.requestSignIn() == .onboarding)
        precondition(firstRun.isSignInStep)
        firstRun.next(isSignedIn: true)
        precondition(firstRun.step == 2)
        for _ in 0..<firstRun.stepCount { firstRun.next(isSignedIn: true) }
        precondition(firstRun.isLastStep && firstRun.step == firstRun.stepCount - 1)
        firstRun.finish()
        precondition(!firstRun.isPresented)
        precondition(OnboardingState(defaults: defaults).launch(hasSavedSession: false) == .signIn)
        precondition(OnboardingState(defaults: defaults).launch(hasSavedSession: true) == nil)

        firstRun.show()
        precondition(firstRun.step == 0 && firstRun.isPresented)
        firstRun.close()
        precondition(firstRun.requestSignIn() == .signIn)
        precondition(firstRun.sessionChanged(hasSavedSession: false) == .signIn)
        precondition(firstRun.sessionChanged(hasSavedSession: true) == nil)

        defaults.removeObject(forKey: "hasSeenOnboarding")
        let existingUser = OnboardingState(defaults: defaults)
        precondition(existingUser.launch(hasSavedSession: true) == .onboarding)
        existingUser.close()
        precondition(!existingUser.isPresented)
        let reopened = OnboardingState(defaults: defaults)
        precondition(reopened.launch(hasSavedSession: true) == .onboarding)
        // Deferring login continues the guide without marking it complete.
        reopened.showSignIn()
        reopened.skipSignIn()
        precondition(reopened.isPresented && reopened.step == 2)
        precondition(!defaults.bool(forKey: "hasSeenOnboarding"))
        reopened.skipSignIn()
        precondition(reopened.step == 2)
        reopened.previous()
        precondition(reopened.isSignInStep)
        reopened.next(isSignedIn: false)
        precondition(reopened.isSignInStep)
        reopened.skipSignIn()
        reopened.next(isSignedIn: false)
        reopened.next(isSignedIn: false)
        reopened.next(isSignedIn: false)
        precondition(reopened.isLastStep)
        reopened.finish()
        precondition(!reopened.isPresented && defaults.bool(forKey: "hasSeenOnboarding"))
        precondition(OnboardingState(defaults: defaults).launch(hasSavedSession: true) == nil)
        precondition(OnboardingState(defaults: defaults).launch(hasSavedSession: false) == .signIn)
        reopened.show()
        precondition(reopened.step == 0 && reopened.isPresented)
        reopened.close()
        reopened.next(isSignedIn: true)
        precondition(reopened.step == 0)
        print("Onboarding checks passed")
    }
}
