import Foundation
import os.log

/// Categorized os.log loggers, viewable in Console.app under
/// subsystem `ai.deepseek.dsh.desktop`. `Logger` is the Swift wrapper
/// over the C `os_log_t`; log lines show up with category tags for
/// filtering.
public enum Log {

    /// Subsystem used for all `Log.*` loggers.
    public static let subsystem = "ai.deepseek.dsh.desktop"

    public static let app      = Logger(subsystem: subsystem, category: "app")
    public static let dsh      = Logger(subsystem: subsystem, category: "dsh")
    public static let network  = Logger(subsystem: subsystem, category: "network")
    public static let ui       = Logger(subsystem: subsystem, category: "ui")
    public static let errors   = Logger(subsystem: subsystem, category: "errors")
    public static let menu     = Logger(subsystem: subsystem, category: "menu")
}