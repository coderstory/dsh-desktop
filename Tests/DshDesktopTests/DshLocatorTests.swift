import Testing
import Foundation
@testable import DshDesktop

@Suite("DshLocator")
struct DshLocatorTests {

    @Test func locate_dshFound_returnsLocation() throws {
        // Real `which dsh` should succeed in the dev environment.
        let location = try DshLocator.locate()
        #expect(location.executablePath.hasSuffix("/dsh"))
        #expect(location.executablePath.hasPrefix("/"))
        #expect(location.arguments == ["dsh", "--profile", "web"])
    }

    @Test func locate_dshNotFound_throwsNotInstalled() {
        let stub: DshLocator.WhichFunc = { _ in nil }
        #expect(throws: DshLocatorError.notInstalled) {
            try DshLocator.locate(which: stub)
        }
    }

    @Test func locate_customWhich_returnsCustomPath() throws {
        let stub: DshLocator.WhichFunc = { name in
            name == "dsh" ? "/custom/path/to/dsh" : nil
        }
        let location = try DshLocator.locate(which: stub)
        #expect(location.executablePath == "/custom/path/to/dsh")
    }

    @Test func locateError_descriptiveMessage_includesInstallHint() {
        let error = DshLocatorError.notInstalled
        let description = error.errorDescription ?? ""
        #expect(description.contains("npm install"))
        #expect(description.contains("dsh"))
    }
}