import Testing
import Foundation
@testable import DshDesktop

@Suite("Preferences")
@MainActor
struct PreferencesTests {

    /// Per-test UserDefaults suite so writes don't leak between tests.
    private func makeFresh() -> (Preferences, UserDefaults, String) {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let prefs = Preferences(defaults: defaults)
        return (prefs, defaults, suiteName)
    }

    @Test func init_withEmptyDefaults_usesFactoryDefaults() {
        let (prefs, _, _) = makeFresh()
        #expect(prefs.port == Preferences.defaultPort)
        #expect(prefs.port == 3080)
        #expect(prefs.notificationsEnabled == true)
    }

    @Test func setting_port_persistsAcrossInstances() {
        let (prefs1, defaults, suiteName) = makeFresh()
        prefs1.port = 8080
        let prefs2 = Preferences(defaults: defaults)
        #expect(prefs2.port == 8080)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func setting_notificationsEnabled_persistsAcrossInstances() {
        let (prefs1, defaults, suiteName) = makeFresh()
        prefs1.notificationsEnabled = false
        let prefs2 = Preferences(defaults: defaults)
        #expect(prefs2.notificationsEnabled == false)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func init_invalidPortInDefaults_fallsBackToDefault() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(999_999, forKey: Preferences.Keys.port)
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.port == Preferences.defaultPort)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func resetToDefaults_restoresAllToFactory() {
        let (prefs, _, _) = makeFresh()
        prefs.port = 8080
        prefs.notificationsEnabled = false
        prefs.resetToDefaults()
        #expect(prefs.port == Preferences.defaultPort)
        #expect(prefs.notificationsEnabled == true)
    }
}