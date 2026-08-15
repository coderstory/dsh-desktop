import Foundation

/// Parsed command-line configuration. The wrapper exposes four knobs:
/// port override (`--port`), external-only mode (`--no-spawn`), verbose
/// logging (`--debug`), and help (`--help` / `-h`).
public struct LaunchConfig: Equatable {

    public let port: Int
    public let noSpawn: Bool
    public let debug: Bool
    public let help: Bool

    public init(port: Int = 3080, noSpawn: Bool = false, debug: Bool = false, help: Bool = false) {
        self.port = port
        self.noSpawn = noSpawn
        self.debug = debug
        self.help = help
    }

    public static let `default` = LaunchConfig()

    public static let helpText = """
    DshDesktop — native macOS wrapper for dsh --profile web

    Usage: DshDesktop [options]

    Options:
      --port <N>        TCP port dsh serves on (default: 3080)
      --no-spawn        Don't launch dsh; connect to existing instance on --port
      --debug           Enable verbose os.log output
      --help, -h        Show this help and exit

    Examples:
      DshDesktop                       # normal: spawn dsh on 3080
      DshDesktop --port 8080           # dsh is on a different port
      DshDesktop --no-spawn             # use an externally-managed dsh
    """

    /// Parses argv. `argv[0]` is the executable path and is skipped.
    /// Exits with code 2 on invalid arguments (prints to stderr).
    public static func parse(_ argv: [String]) -> LaunchConfig {
        var port = 3080
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
                fail("unknown argument: \(arg)")
            }
        }
        return LaunchConfig(port: port, noSpawn: noSpawn, debug: debug, help: help)
    }

    /// Computed so tests that don't access `.current` never trigger argv parsing.
    public static var current: LaunchConfig { parse(CommandLine.arguments) }

    private static func fail(_ message: String) -> Never {
        fputs("dsh-desktop: \(message)\n  Run with --help for usage.\n", stderr)
        exit(2)
    }
}