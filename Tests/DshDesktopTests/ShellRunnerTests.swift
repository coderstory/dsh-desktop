import Testing
import Foundation
@testable import DshDesktop

@Suite("ShellRunner")
struct ShellRunnerTests {

    @Test func run_withEcho_returnsSuccessAndOutput() async {
        let result = await ShellRunner.run("/bin/echo", ["hello", "world"])
        #expect(result.success == true)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("hello world"))
    }

    @Test func run_withNonZeroExit_returnsFailureAndExitCode() async {
        let result = await ShellRunner.run("/bin/sh", ["-c", "echo oops 1>&2; exit 7"])
        #expect(result.success == false)
        #expect(result.exitCode == 7)
        #expect(result.output.contains("oops"))
    }

    @Test func run_withNonexistentExecutable_returnsFailureWithMessage() async {
        let result = await ShellRunner.run("/nonexistent/binary/xyz", [])
        #expect(result.success == false)
        #expect(result.exitCode == -1)
        #expect(result.output.contains("failed to launch"))
    }

    @Test func run_capturesStderrToo() async {
        let result = await ShellRunner.run("/bin/sh", ["-c", "echo stdout-msg; echo stderr-msg 1>&2"])
        #expect(result.output.contains("stdout-msg"))
        #expect(result.output.contains("stderr-msg"))
    }
}