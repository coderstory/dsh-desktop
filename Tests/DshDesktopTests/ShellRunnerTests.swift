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

@Suite("ShellRunner env parsing")
struct ShellRunnerEnvTests {

    @Test func parseEnvZero_handlesKeyValuePairs() {
        let data = Data("PATH=/usr/bin\0HOME=/Users/test\0LANG=en\0".utf8)
        let env = ShellRunner.parseEnvZero(data)
        #expect(env?["PATH"] == "/usr/bin")
        #expect(env?["HOME"] == "/Users/test")
        #expect(env?["LANG"] == "en")
        #expect(env?.count == 3)
    }

    @Test func parseEnvZero_handlesEqualsInValue() {
        let data = Data("TOKEN=a=b=c\0".utf8)
        let env = ShellRunner.parseEnvZero(data)
        #expect(env?["TOKEN"] == "a=b=c")
    }

    @Test func parseEnvZero_emptyData_returnsNil() {
        #expect(ShellRunner.parseEnvZero(Data()) == nil)
    }

    @Test func parseEnvZero_garbageLinesSkipped() {
        let data = Data("VALID=x\0NOEQUALS\0ALSO=y\0".utf8)
        let env = ShellRunner.parseEnvZero(data)
        #expect(env?["VALID"] == "x")
        #expect(env?["ALSO"] == "y")
        #expect(env?.count == 2)
    }

    @Test func loginShellEnvironment_returnsNonEmptyOnDev() async {
        // Real zsh is on the dev box. Should return at least the typical
        // vars (PATH, HOME, USER, etc.) from the login shell env.
        guard let env = await ShellRunner.loginShellEnvironment() else {
            Issue.record("loginShellEnvironment returned nil")
            return
        }
        #expect(env["PATH"]?.isEmpty == false)
        #expect(env["HOME"]?.isEmpty == false)
        // PATH should include the npm-global bin (where `dsh` lives).
        #expect(env.count > 3)
    }
}