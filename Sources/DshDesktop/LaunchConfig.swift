import Foundation

/// Parsed command-line configuration. The wrapper exposes:
/// port override (`--port`), external-only mode (`--no-spawn`), verbose
/// logging (`--debug`), help (`--help` / `-h`), and an explicit dsh-binary
/// path (`--dsh-path`) for the case where shell-based lookup fails
/// (e.g. PATH is set in `~/.zshrc` which `zsh -l -c` doesn't source).
public struct LaunchConfig: Equatable, Sendable {

    /// When `nil`, `current` falls back to `Preferences.shared.port`.
    public let port: Int?
    /// When set, skip shell-based `which` and use this path directly.
    public let dshPath: String?
    public let noSpawn: Bool
    public let debug: Bool
    public let help: Bool

    public init(
        port: Int? = nil,
        dshPath: String? = nil,
        noSpawn: Bool = false,
        debug: Bool = false,
        help: Bool = false
    ) {
        self.port = port
        self.dshPath = dshPath
        self.noSpawn = noSpawn
        self.debug = debug
        self.help = help
    }

    public static let `default` = LaunchConfig()

    /// Resolved port: CLI override wins, otherwise Preferences, otherwise 3080.
    public var resolvedPort: Int {
        port ?? Preferences.shared.port
    }

    public static let helpText = """
    DshDesktop — native macOS wrapper for dsh --profile web

    Usage: DshDesktop [options]

    Options:
      --port <N>        TCP port dsh serves on (default: \(Preferences.defaultPort) or from Preferences)
      --dsh-path <P>     Absolute path to dsh (skips shell-based lookup)
      --no-spawn        Don't launch dsh; connect to existing instance on --port
      --debug           Enable verbose os.log output
      --help, -h        Show this help and exit

    Examples:
      DshDesktop                       # normal: spawn dsh on \(Preferences.defaultPort)
      DshDesktop --port 8080           # dsh is on a different port
      DshDesktop --dsh-path ~/bin/dsh  # explicit binary path
      DshDesktop --no-spawn             # use an externally-managed dsh
    """

    /// Parses argv. `argv[0]` is the executable path and is skipped.
    /// Unknown flags are silently ignored (useful when the Swift test runner
    /// passes flags like `--test-bundle-path`).
    /// Exits with code 2 on invalid arguments (prints to stderr).
    public static func parse(_ argv: [String]) -> LaunchConfig {
        var port: Int? = nil
        var dshPath: String? = nil
        var noSpawn = false
        var debug = false
        var help = false

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "--port":
                if i + 1 >= argv.count {
                    fail("--port requires a number")
                }
                guard let n = Int(argv[i + 1]), n > 0, n < 65536 else {
                    fail("--port must be a positive integer < 65536, got \(argv[i + 1])")
                }
                port = n
                i += 2
            case "--dsh-path":
                if i + 1 >= argv.count {
                    fail("--dsh-path requires a path")
                }
                let p = argv[i + 1]
                guard !p.isEmpty else {
                    fail("--dsh-path cannot be empty")
                }
                dshPath = p
                i += 2
            case "--no-spawn":
                noSpawn = true
                i += 1
            case "--debug":
                debug = true
                i += 1
            case "--help", "-h":
                help = true
                i += 1
            default:
                // Silently ignore unknown flags. This makes the wrapper
                // robust to host-injected args (test runner, Xcode, etc.).
                i += 1
            }
        }
        return LaunchConfig(
            port: port, dshPath: dshPath, noSpawn: noSpawn, debug: debug, help: help
        )
    }

    /// Computed so tests that don't access `.current` never trigger argv parsing.
    /// CLI explicit --port wins; otherwise falls back to the supplied preferences
    /// (defaults to `Preferences.shared`).
    public static func current(preferences: Preferences = .shared) -> LaunchConfig {
        let cli = parse(CommandLine.arguments)
        return LaunchConfig(
            port: cli.port ?? preferences.port,
            dshPath: cli.dshPath,
            noSpawn: cli.noSpawn,
            debug: cli.debug,
            help: cli.help
        )
    }

    private static func fail(_ message: String) -> Never {
        fputs("dsh-desktop: \(message)\n  Run with --help for usage.\n", stderr)
        exit(2)
    }
}