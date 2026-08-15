import Testing
@testable import DshDesktop

@Test func appStructExists() {
    // Sanity check that DshApp compiles in test target. The mere presence
    // of `@testable import DshDesktop` above is what exercises the compile;
    // the reference below keeps the symbol live for the test discovery pass.
    _ = DshApp.self
}
