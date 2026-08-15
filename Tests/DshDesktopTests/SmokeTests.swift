import Testing
@testable import DshDesktop

@Test func appStructExists() {
    // Sanity check that DshApp compiles in test target.
    _ = DshApp.self
}