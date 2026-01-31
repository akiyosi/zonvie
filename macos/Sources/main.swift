import Cocoa
import Darwin
import Metal

// C functions for fork/setsid (Swift's Darwin.fork is unavailable)
@_silgen_name("fork") private func c_fork() -> Int32
@_silgen_name("setsid") private func c_setsid() -> Int32

// Check for --nofork and --help early (before any other processing)
let args = CommandLine.arguments
let noforkMode = args.contains("--nofork")

// Check if SSH or devcontainer mode (window should be hidden until auth completes)
let sshModeEnabled = args.contains { $0.hasPrefix("--ssh=") }
let devcontainerModeEnabled = args.contains { $0.hasPrefix("--devcontainer=") }

// Collect arguments that are NOT zonvie-specific (these will be passed to nvim)
// zonvie-specific arguments:
//   --nofork, --log <path>, --extcmdline, --extpopup, --extpopupmenu,
//   --extmessages, --exttabline, --ssh=*, --ssh-identity=*,
//   --devcontainer=*, --devcontainer-config=*, --devcontainer-rebuild,
//   --help, -h
// After "--", all remaining arguments are passed to nvim
var nvimExtraArgs: [String] = []
do {
    var i = 1  // Skip argv[0] (executable path)
    var passAllToNvim = false
    while i < args.count {
        let arg = args[i]

        // After "--", pass all remaining arguments to nvim
        if arg == "--" {
            passAllToNvim = true
            i += 1
            continue
        }

        if passAllToNvim {
            nvimExtraArgs.append(arg)
            i += 1
            continue
        }

        // Check for zonvie-specific arguments
        if arg == "--nofork" || arg == "--help" || arg == "-h" ||
           arg == "--extcmdline" || arg == "--extpopup" || arg == "--extpopupmenu" ||
           arg == "--extmessages" || arg == "--exttabline" || arg == "--devcontainer-rebuild" {
            // Skip this argument (it's zonvie-specific)
            i += 1
        } else if arg == "--log" {
            // Skip --log and its value
            i += 2
        } else if arg.hasPrefix("--ssh=") || arg.hasPrefix("--ssh-identity=") ||
                  arg.hasPrefix("--devcontainer=") || arg.hasPrefix("--devcontainer-config=") {
            // Skip =value style arguments
            i += 1
        } else {
            // Not a zonvie argument - pass to nvim
            nvimExtraArgs.append(arg)
            i += 1
        }
    }
}

// Detect if launched from Finder (no TERM environment variable)
// When launched from Finder, we must NOT fork to receive openFile events
let launchedFromFinder = ProcessInfo.processInfo.environment["TERM"] == nil

// When launched from Finder, load environment variables from user's login shell
// This ensures PATH and other variables are available (needed for LSPs, node, etc.)
if launchedFromFinder {
    loadShellEnvironment()
}

func loadShellEnvironment() {
    // Get user's default shell
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    // Run login shell to get environment variables
    let task = Process()
    task.executableURL = URL(fileURLWithPath: shell)
    task.arguments = ["-l", "-c", "env"]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            // Parse and set environment variables
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0])
                    let value = String(parts[1])
                    setenv(key, value, 1)
                }
            }
        }
    } catch {
        // Silently ignore errors - fall back to default environment
    }
}

// Handle --help before fork (so output goes to terminal)
if args.contains("--help") || args.contains("-h") {
    let help = """
        zonvie - A high-performance Neovim GUI

        USAGE:
            zonvie [OPTIONS]

        OPTIONS:
            --nofork                      Don't fork; stay attached to terminal, keep cwd
            --log <path>                  Write application logs to specified file path
            --extcmdline                  Enable external command line UI
            --extpopup, --extpopupmenu    Enable external popup menu UI
            --extmessages                 Enable external messages UI
            --exttabline                  Enable external tabline UI (Chrome-style tabs)
            --ssh=<user@host[:port]>      Connect to remote host via SSH
            --ssh-identity=<path>         Path to SSH private key file
            --devcontainer=<workspace>    Run inside a devcontainer
            --devcontainer-config=<path>  Path to devcontainer.json
            --devcontainer-rebuild        Rebuild devcontainer before starting
            --help, -h                    Show this help message and exit
            --                            Pass all remaining arguments to nvim

        CONFIG:
            Configuration file: ~/.config/zonvie/config.toml
            (or $XDG_CONFIG_HOME/zonvie/config.toml)

            [neovim]
                path            Path to Neovim executable
                ssh             Enable SSH mode (true/false)
                ssh_host        SSH host (user@host format)
                ssh_port        SSH port number
                ssh_identity    Path to SSH private key

            [font]
                family          Font family name
                size            Font size in points
                linespace       Extra line spacing in pixels

            [window]
                blur            Enable blur effect (true/false)
                opacity         Background opacity (0.0-1.0, when blur=true)
                blur_radius     Blur radius (1-100, when blur=true)

            [cmdline]
                external        Enable external command line UI

            [popup]
                external        Enable external popup menu UI

            [messages]
                external        Enable external messages UI

            [log]
                enabled         Enable logging (true/false)
                path            Log file path

            [performance]
                glyph_cache_ascii_size      ASCII glyph cache size (min: 128)
                glyph_cache_non_ascii_size  Non-ASCII glyph cache size (min: 64)

        For more information, visit: https://github.com/akiyosi/zonvie
        """
    print(help)
    exit(0)
}

if !noforkMode && !launchedFromFinder {
    // Check if pipeline cache exists BEFORE deciding to fork.
    // If cache doesn't exist, we must NOT fork because:
    // 1. Metal shader compilation requires XPC service
    // 2. XPC services don't survive fork()
    // 3. Metal initialization before fork() poisons FileManager for child process
    //
    // First launch will run without fork (like --nofork mode) to build cache.
    // Subsequent launches will fork normally and load from cache.
    var shouldFork = false

    if let home = getenv("HOME") {
        let homeStr = String(cString: home)
        let archivePath = homeStr + "/Library/Application Support/zonvie/pipeline_cache.metallib"

        var st = stat()
        let cacheExists = stat(archivePath, &st) == 0

        if cacheExists {
            // Cache exists - safe to fork
            shouldFork = true
        } else {
            // No cache - run without fork to build it
            // This only happens on first launch
            print("Pipeline cache not found, running without fork to build cache...")
        }
    } else {
        // Can't determine home directory, skip fork
        print("Warning: Cannot determine HOME directory, running without fork")
    }

    if shouldFork {
        // Default mode: fork and detach from terminal
        // This allows the terminal prompt to return immediately
        let pid = c_fork()
        if pid < 0 {
            // Fork failed - continue in current process
            perror("fork")
        } else if pid > 0 {
            // Parent process: exit immediately (returns prompt to terminal)
            exit(0)
        }
        // Child process continues below

        // Become session leader (detach from controlling terminal)
        _ = c_setsid()

        // Redirect standard file descriptors to /dev/null (not close!)
        // Closing them would make fd 0,1,2 available for reuse, which breaks
        // child process spawning in Zig (fchdir uses these fd numbers)
        let devnull = open("/dev/null", O_RDWR)
        if devnull >= 0 {
            dup2(devnull, STDIN_FILENO)
            dup2(devnull, STDOUT_FILENO)
            dup2(devnull, STDERR_FILENO)
            if devnull > STDERR_FILENO {
                close(devnull)
            }
        }

        // Change to $HOME since we're detached from terminal
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            FileManager.default.changeCurrentDirectoryPath(home)
        }
    }
}
// --nofork mode or no cache: keep current directory, stay attached to terminal

// Configure logging before anything else
// CLI --log takes precedence over config file
var cliLogPath: String? = nil
for i in 0..<args.count {
    if args[i] == "--log" && i + 1 < args.count {
        cliLogPath = args[i + 1]
        break
    }
}

let config = ZonvieConfig.shared
if let logPath = cliLogPath {
    ZonvieCore.configureLogging(enabled: true, filePath: logPath)
} else if config.log.enabled {
    ZonvieCore.configureLogging(enabled: true, filePath: config.log.path)
} else {
    ZonvieCore.configureLogging(enabled: false, filePath: nil)
}

// Log config info after logging is configured
ZonvieCore.appLog("[Config] Loading config from \(ZonvieConfig.configFilePath.path)")
ZonvieCore.appLog("[Config] LOADED: blur=\(config.window.blur) opacity=\(config.window.opacity) blurRadius=\(config.window.blurRadius) blurEnabled=\(config.blurEnabled) backgroundAlpha=\(config.backgroundAlpha)")
ZonvieCore.appLog("[Startup] cwd=\(FileManager.default.currentDirectoryPath) nofork=\(noforkMode) launchedFromFinder=\(launchedFromFinder)")
ZonvieCore.appLog("[Startup] args=\(args)")

// Force an AppKit entry point without relying on Info.plist / storyboard wiring.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// Exit with Neovim's exit code (only meaningful in --nofork mode)
// In fork mode, the parent process already exited with 0, so child's exit code
// is not visible to the terminal.
Darwin.exit(ZonvieCore.getExitCode())

