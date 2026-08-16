import Foundation

/// Locates the `dsh` executable on the user's `$PATH`.
/// Used at app launch to fail fast with a friendly "install dsh first" message
/// instead of a cryptic "command not found" from Process.
public enum DshLocator {

    public struct Location: Equatable {
        public let executablePath: String
        public let arguments: [String]   // typically `["dsh", "--profile", "web"]`
    }

    /// Mockable `which`-style function. Returns the absolute path to a binary
    /// on `$PATH`, or nil if not found.
    public typealias WhichFunc = @Sendable (String) -> String?

    /// Default implementation: tries multiple lookup strategies in order of
    /// reliability. GUI apps launched from Finder/Dock inherit a minimal
    /// PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) which excludes npm-global bin
    /// (e.g. `~/.npm-global/bin` or `~/.global-npm/bin`).
    ///
    /// The shell strategies use `zsh -l -c` / `bash -l -c` (login shells
    /// source `~/.zprofile` / `~/.bash_profile`). We also explicitly source
    /// `~/.zshrc` / `~/.bashrc` (interactive configs where users typically
    /// put `export PATH=...`).
    ///
    /// As a fully shell-independent fallback, we also ask `npm config get
    /// prefix` for the global npm install location and look in `<prefix>/bin`.
    public static let whichDefault: WhichFunc = { name in
        let candidates = buildLookupCandidates(name: name)
        for cmd in candidates {
            if let path = runShell(cmd.shell, cmd.args, name) {
                return path
            }
        }
        Log.errors.error(
            "DshLocator: '\(name)' not found via any strategy (login shell + interactive config + npm prefix + env which)"
        )
        return nil
    }

    private struct LookupCmd {
        let shell: String
        let args: [String]

        init(_ shell: String, _ args: [String]) {
            self.shell = shell
            self.args = args
        }
    }

    /// All strategies in priority order. The first one that returns an
    /// absolute path wins.
    private static func buildLookupCandidates(name: String) -> [LookupCmd] {
        return [
            // 1. zsh login shell, then source interactive config. Users
            //    typically put `export PATH=...` in `~/.zshrc`, which is
            //    NOT sourced by `zsh -l` alone.
            LookupCmd("/bin/zsh", ["-l", "-c", "test -r ~/.zshrc && source ~/.zshrc; command -v \(name)"]),

            // 2. bash login shell, then source interactive config.
            LookupCmd("/bin/bash", ["-l", "-c", "test -r ~/.bashrc && source ~/.bashrc; command -v \(name)"]),

            // 3. zsh login shell only (catches PATH in `~/.zprofile` /
            //    `~/.zshenv`).
            LookupCmd("/bin/zsh", ["-l", "-c", "command -v \(name)"]),

            // 4. bash login shell only.
            LookupCmd("/bin/bash", ["-l", "-c", "command -v \(name)"]),

            // 5. npm global prefix — Node-aware, no shell init. Looks in
            //    `<prefix>/bin/dsh`. Works on systems where `npm i -g
            //    @deepseek-ai/dsh` was used to install but PATH is broken.
            LookupCmd("/usr/bin/env", ["sh", "-c", "npm config get prefix 2>/dev/null | xargs -I {} test -x {}/bin/\(name) && echo {}/bin/\(name)"]),

            // 6. Last resort: plain `env which` (minimal PATH — may fail).
            LookupCmd("/usr/bin/env", ["which", name]),
        ]
    }

    private static func runShell(_ shell: String, _ args: [String], _ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            Log.errors.error("DshLocator: failed to spawn \(shell): \(error.localizedDescription)")
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            Log.app.info("DshLocator: \(shell) returned exit \(proc.terminationStatus) for `\(name)`")
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Locate `dsh` on `$PATH`. Throws `DshLocatorError.notInstalled` if absent.
    public static func locate(which: WhichFunc = whichDefault) throws -> Location {
        guard let path = which("dsh") else {
            throw DshLocatorError.notInstalled
        }
        Log.dsh.info("located dsh at \(path)")
        // Use `dsh --profile web` (NOT `dsh web` subcommand) because
        // dsh 0.1.0-rc.6 has a bug: the parent command's greedy
        // .argument plus enablePositionalOptions swallows `web` as a
        // positional arg, the web subcommand never matches, and the
        // parent action emits `error: --profile <name> is required`.
        //
        // Direct test of dsh's argv handling:
        //   dsh web --port 13080          fails with --profile required
        //   dsh --profile web --port 13080 boots web profile
        //
        // Foundation's Process `arguments` becomes argv[1+] for the spawned
        // process (Foundation does NOT prepend executableURL — verified
        // empirically with /bin/echo). The kernel then invokes the
        // shebang interpreter, so dsh's bin.js (Node) sees process.argv
        // = [node, bin_js_path, ...Foundation arguments]. dsh does
        // `process.argv.slice(2)`, which lands on Foundation `arguments`
        // verbatim. So we pass ONLY the user args here.
        //
        // Earlier mistakes:
        //   - ['dsh', '--profile', 'web'] → slice(2) = ['web', ...]
        //     commander treats 'web' as program name, options.profile
        //     is undefined, parent's check fires '--profile required'.
        //   - ['x','x','dsh','--profile','web'] (2-padding) → slice(2)
        //     = ['dsh','--profile',...] but commander's greedy
        //     positional captures 'dsh' before '--profile' is parsed,
        //     same '--profile required' failure.
        //   - ['--profile','web'] (clean form) → slice(2) =
        //     ['--profile','web',...]. commander parses '--profile'
        //     as parent option, options.profile='web', parent's check
        //     passes, web profile boots.
        //
        // Verified empirically: Foundation argv = ['--profile','web',
        // '--port','13080'] → dsh web server starts on 13080.
        // Foundation argv = ['dsh','--profile','web','--port','13080']
        // → exit 1 with 'error: --profile <name> is required'.
        //
        // DshProcess appends `--port N` (and any plugin patch)
        // afterward.
        return Location(executablePath: path, arguments: ["--profile", "web"])
    }
}

public enum DshLocatorError: LocalizedError {
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return """
            dsh was not found on your PATH.

            Install with:
              npm install -g @deepseek-ai/dsh

            Then make sure your shell's PATH includes the global npm bin
            directory (usually ~/.npm-global/bin or /usr/local/bin).

            If dsh is installed but not detected, launch DshDesktop from the
            same shell where `which dsh` works, or pass --dsh-path to point
            at the binary directly:
              DshDesktop --dsh-path /Users/you/.global-npm/bin/dsh
            """
        }
    }
}
