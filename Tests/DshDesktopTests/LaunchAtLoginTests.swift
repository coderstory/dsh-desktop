import Testing
import Foundation
@testable import DshDesktop

@Suite("LaunchAtLogin")
struct LaunchAtLoginTests {

    final class MockProvider: LoginItemProviding {
        var currentStatus: LoginItemStatus
        var registerCalled = 0
        var unregisterCalled = 0
        var errorToThrow: Error?

        init(initial: LoginItemStatus = .notRegistered) {
            self.currentStatus = initial
        }

        var status: LoginItemStatus { currentStatus }

        func register() throws {
            registerCalled += 1
            if let error = errorToThrow { throw error }
            currentStatus = .enabled
        }

        func unregister() throws {
            unregisterCalled += 1
            if let error = errorToThrow { throw error }
            currentStatus = .notRegistered
        }
    }

    @Test func isEnabled_returnsTrueWhenProviderEnabled() {
        let mock = MockProvider(initial: .enabled)
        #expect(LaunchAtLogin.isEnabled(provider: mock))
    }

    @Test func isEnabled_returnsFalseWhenProviderNotRegistered() {
        let mock = MockProvider(initial: .notRegistered)
        #expect(!LaunchAtLogin.isEnabled(provider: mock))
    }

    @Test func toggle_whenDisabled_registers() {
        let mock = MockProvider(initial: .notRegistered)
        LaunchAtLogin.toggle(provider: mock)
        #expect(mock.registerCalled == 1)
        #expect(mock.unregisterCalled == 0)
    }

    @Test func toggle_whenEnabled_unregisters() {
        let mock = MockProvider(initial: .enabled)
        LaunchAtLogin.toggle(provider: mock)
        #expect(mock.unregisterCalled == 1)
        #expect(mock.registerCalled == 0)
    }

    @Test func toggle_swallowsErrors_silently() {
        let mock = MockProvider(initial: .notRegistered)
        mock.errorToThrow = NSError(domain: "test", code: 1)
        LaunchAtLogin.toggle(provider: mock)
        #expect(mock.registerCalled == 1)
        // No crash — error logged but not propagated.
    }
}