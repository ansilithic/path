import Foundation

/// Standard exit codes for CLI tools.
public enum CLIExitCode: Int32, Sendable {
    case success = 0
    case warning = 1
    case error = 2

    /// Terminate the process with this exit code.
    public func exit() -> Never {
        Darwin.exit(rawValue)
    }
}
