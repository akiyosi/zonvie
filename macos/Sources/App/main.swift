import Cocoa
import Darwin
import Metal


// Ignore SIGPIPE to prevent crashes when nvim exits and pipes break
signal(SIGPIPE, SIG_IGN)

// Check for --nofork and --help early (before any other processing)
let args = CommandLine.arguments

// `zonvieArgs` is the argv slice up to (but not including) the first `--`.
// Anything after `--` is forwarded verbatim to nvim and must NOT be parsed
// as a zonvie option, otherwise `zonvie -- --ssh=...` would erroneously
// flip on SSH mode (and similar for --connect-nvim, --devcontainer, etc.).
let zonvieArgs: [String] = {
    if let sep = args.firstIndex(of: "--") {
        return Array(args[..<sep])
    }
    return args
}()

let noforkMode = zonvieArgs.contains("--nofork")

// Check if SSH or devcontainer mode (window should be hidden until auth completes)
let sshModeEnabled = zonvieArgs.contains { $0.hasPrefix("--ssh=") || $0 == "--ssh" }
let devcontainerModeEnabled = zonvieArgs.contains { $0.hasPrefix("--devcontainer=") || $0 == "--devcontainer" }

// Collect arguments that are NOT zonvie-specific (these will be passed to nvim)
// zonvie-specific arguments:
//   --nofork, --nvim <path>, --log <path>, --extcmdline, --extpopup, --extpopupmenu,
//   --extmessages, --exttabline, --extwindows, --ssh=*, --ssh-identity=*,
//   --devcontainer=*, --devcontainer-config=*, --devcontainer-rebuild,
//   --connect-nvim=*, --remote-ui=* (alias),
//   --help, -h
// After "--", all remaining arguments are passed to nvim
var cliNvimPath: String? = nil
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
           arg == "--extmessages" || arg == "--exttabline" || arg == "--extwindows" ||
           arg == "--devcontainer-rebuild" || arg == "--install" || arg == "--version" {
            // Skip this argument (it's zonvie-specific)
            i += 1
        } else if arg == "--nvim" {
            // Skip --nvim and its value (nvim path override, space-separated)
            if i + 1 < args.count {
                cliNvimPath = args[i + 1]
            }
            i += 2
        } else if arg.hasPrefix("--nvim=") {
            // --nvim=<path> (equals-separated)
            cliNvimPath = String(arg.dropFirst("--nvim=".count))
            i += 1
        } else if arg == "--log" {
            // Skip --log and its value
            i += 2
        } else if arg == "--ssh" || arg == "--ssh-identity" ||
                  arg == "--devcontainer" || arg == "--devcontainer-config" ||
                  arg == "--connect-nvim" || arg == "--remote-ui" {
            // Skip space-separated value arguments (--ssh host, --devcontainer path, etc.)
            i += 2
        } else if arg.hasPrefix("--ssh=") || arg.hasPrefix("--ssh-identity=") ||
                  arg.hasPrefix("--devcontainer=") || arg.hasPrefix("--devcontainer-config=") ||
                  arg.hasPrefix("--connect-nvim=") || arg.hasPrefix("--remote-ui=") {
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

// Handle --help before fork (so output goes to terminal).
// Use zonvieArgs so `zonvie -- --help` forwards `--help` to nvim
// instead of printing zonvie's own help text and exiting.
if zonvieArgs.contains("--help") || zonvieArgs.contains("-h") {
    let help = """
        zonvie - A high-performance Neovim GUI

        USAGE:
            zonvie [OPTIONS]

        OPTIONS:
            --nofork                      Don't fork; stay attached to terminal, keep cwd
            --nvim <path>                 Path to Neovim executable (overrides config)
            --log <path>                  Write application logs to specified file path
            --extcmdline                  Enable external command line UI
            --extpopup, --extpopupmenu    Enable external popup menu UI
            --extmessages                 Enable external messages UI
            --exttabline                  Enable external tabline UI (Chrome-style tabs)
            --extwindows                  Enable external windows (each Neovim window as OS window)
            --ssh=<user@host[:port]>      Connect to remote host via SSH
            --ssh-identity=<path>         Path to SSH private key file
            --devcontainer=<workspace>    Run inside a devcontainer
            --devcontainer-config=<path>  Path to devcontainer.json
            --devcontainer-rebuild        Rebuild devcontainer before starting
            --connect-nvim=<addr>         Attach to a running Neovim server.
                                            Address: TCP "host:port" or Unix socket path.
                                            Mutually exclusive with --ssh / --devcontainer.
            --remote-ui=<addr>            Alias of --connect-nvim, mirrors `nvim --remote-ui`.
            --install                     Create default config file and exit
            --version                     Show version information and exit
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

            [tabline]
                external            Enable external tabline UI
                style               Display style: "titlebar", "menu", "sidebar" (default: "titlebar")
                sidebar_position    Sidebar position: "left" or "right" (default: "left")
                sidebar_width       Sidebar width in pixels (100-500, default: 200)

            [windows]
                external        Enable external windows

            [log]
                enabled         Enable logging (true/false)
                path            Log file path

            [performance]
                glyph_cache_ascii_size      ASCII glyph cache size (min: 128)
                glyph_cache_non_ascii_size  Non-ASCII glyph cache size (min: 64)
                hl_cache_size               Highlight cache size (64-2048, default: 512)

        For more information, visit: https://github.com/akiyosi/zonvie
        """
    print(help)
    exit(0)
}

// Handle --version before fork (so output goes to terminal). Use zonvieArgs so
// `zonvie -- --version` forwards the token to nvim instead of printing here.
if zonvieArgs.contains("--version") {
    print("zonvie \(ZonvieCore.version())")
    exit(0)
}

// Handle --install: create default config.toml and exit.
// Use zonvieArgs so `zonvie -- --install` forwards `--install` to nvim
// (nvim has no such option but the user's intent is clear: don't run
// zonvie's installer just because the token appears post `--`).
if zonvieArgs.contains("--install") {
    let configURL = ZonvieConfig.configFilePath
    let configPath = configURL.path
    let fm = FileManager.default

    if fm.fileExists(atPath: configPath) {
        print("Config file already exists, skipped: \(configPath)")
    } else {
        let dirURL = configURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            fputs("Failed to create config directory: \(error)\n", stderr)
            exit(1)
        }

        let defaultConfig = """
            # Zonvie configuration file
            # See `zonvie --help` for all available options.

            [font]
            # family = "SF Mono"
            # size = 14.0
            # linespace = 0

            [neovim]
            # path = "nvim"

            [window]
            # opacity = 1.0
            # blur = false
            # blur_radius = 20

            """
        do {
            try defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
            print("Default config.toml created: \(configPath)")
        } catch {
            fputs("Failed to write config file: \(error)\n", stderr)
            exit(1)
        }
    }
    exit(0)
}

// Validate flag exclusivity BEFORE the posix_spawnp fork branch below.
// The fork makes the parent exit(0) once the child is spawned, which
// hides any error printed afterwards from the terminal — both because
// the parent has already returned success to the shell, and because
// the child's stdio is redirected to /dev/null. By running the check
// here, a CLI invocation like `zonvie --connect-nvim=... --ssh=...`
// fails synchronously in the foreground process with a visible stderr
// message instead of silently no-op'ing.
//
// `--connect-nvim` attaches to an already-running Neovim server;
// `--ssh` / `--devcontainer` (and their config.toml equivalents
// `[neovim].ssh` / `.wsl`) all SPAWN a wrapper-hosted nvim. The two
// modes are mutually exclusive — silently letting connect mode
// override (the previous behavior) would pick the user's wrapper
// config out from under them. Refuse to start so the user can fix the
// invocation explicitly.
// Detect connect-mode usage AND capture its address in a single pass so
// we can fail fast on bad invocations. Three classes of mistake we catch:
//   1. Conflict with --ssh / --devcontainer (or their config.toml twins)
//   2. Bare --connect-nvim / --remote-ui with no following value, which
//      previously fell through silently to a regular nvim spawn
//   3. --connect-nvim= or --remote-ui= with an empty value, which
//      previously entered connect mode with addr=="" and surfaced as
//      a confusing "Invalid core handle" alert from ZonvieCore.start.
var connectModeEnabled = false
var connectAddrCaptured: String? = nil
do {
    var i = 0
    while i < zonvieArgs.count {
        let arg = zonvieArgs[i]
        if arg.hasPrefix("--connect-nvim=") {
            connectModeEnabled = true
            connectAddrCaptured = String(arg.dropFirst("--connect-nvim=".count))
        } else if arg == "--connect-nvim" {
            connectModeEnabled = true
            if i + 1 < zonvieArgs.count {
                connectAddrCaptured = zonvieArgs[i + 1]
                i += 1
            } else {
                connectAddrCaptured = nil
            }
        } else if arg.hasPrefix("--remote-ui=") {
            connectModeEnabled = true
            connectAddrCaptured = String(arg.dropFirst("--remote-ui=".count))
        } else if arg == "--remote-ui" {
            connectModeEnabled = true
            if i + 1 < zonvieArgs.count {
                connectAddrCaptured = zonvieArgs[i + 1]
                i += 1
            } else {
                connectAddrCaptured = nil
            }
        }
        i += 1
    }
}
if connectModeEnabled {
    // (1) value missing or empty
    if connectAddrCaptured == nil || connectAddrCaptured!.isEmpty {
        let stderrMsg = "zonvie: --connect-nvim / --remote-ui requires a non-empty address (e.g. /tmp/nvim.sock or 127.0.0.1:6789).\n"
        fputs(stderrMsg, stderr)
        if launchedFromFinder {
            _ = NSApplication.shared
            let alert = NSAlert()
            alert.messageText = "zonvie: invalid options"
            alert.informativeText = "--connect-nvim / --remote-ui requires a non-empty address such as /tmp/nvim.sock or 127.0.0.1:6789."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            _ = alert.runModal()
        }
        Darwin.exit(1)
    }
    // (2) wrapper-mode conflict
    var conflictParts: [String] = []
    if sshModeEnabled || ZonvieConfig.shared.neovim.ssh {
        conflictParts.append("--ssh / [neovim].ssh")
    }
    if devcontainerModeEnabled {
        conflictParts.append("--devcontainer")
    }
    if !conflictParts.isEmpty {
        let conflictDesc = conflictParts.joined(separator: " and ")
        let stderrMsg = "zonvie: --connect-nvim is mutually exclusive with \(conflictDesc).\nRemove the conflicting option(s) and retry.\n"
        fputs(stderrMsg, stderr)
        // Finder launches have no parent terminal to read stderr — pop a
        // modal dialog so the error is visible. Terminal launches see the
        // stderr message above and don't need (and shouldn't get) an
        // alert that would flash on screen and then disappear.
        if launchedFromFinder {
            _ = NSApplication.shared
            let alert = NSAlert()
            alert.messageText = "zonvie: invalid options"
            alert.informativeText = "--connect-nvim is mutually exclusive with \(conflictDesc) (or the corresponding config.toml entry). Remove the conflicting option(s) and retry."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            _ = alert.runModal()
        }
        Darwin.exit(1)
    }
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

    // --connect-nvim / --remote-ui: never fork. The fork pattern below has
    // the parent exit(0) immediately after a successful posix_spawnp,
    // before the child has had a chance to run zonvie_core_start_connect
    // (which can fail synchronously with rc=-3) or fire on_exit(1) from
    // a hot-swap connect failure. With fork, those failures resolve
    // entirely inside a child whose stdio is /dev/null and whose exit
    // code never reaches the parent shell — a script wrapping
    // `zonvie --connect-nvim=...` would see exit 0 even on failure.
    // Foregrounding restores the contract that ViewController.swift
    // handleCoreStartFailure already assumes ("the shell sees a non-
    // zero exit code"). For the common case (terminal launch with no
    // connect mode) the fork still applies.
    if connectModeEnabled {
        shouldFork = false
    }

    if shouldFork {
        // Use posix_spawnp instead of fork to avoid macOS GUI/IME issues after fork.
        // fork() breaks WindowServer/HIToolbox connections needed for IME candidate windows.
        // posix_spawnp searches PATH for executables without "/" in their name.

        // Resolve path BEFORE chdir, since relative paths won't work after chdir($HOME)
        let argv0 = CommandLine.arguments[0]
        let executablePath: String
        if argv0.hasPrefix("/") {
            // Absolute path - use as is
            executablePath = argv0
        } else if argv0.contains("/") {
            // Relative path with directory component (e.g., ./zonvie, ../bin/zonvie)
            // Must resolve to absolute path before chdir
            let cwd = FileManager.default.currentDirectoryPath
            executablePath = (cwd as NSString).appendingPathComponent(argv0)
        } else {
            // Bare name (e.g., zonvie) - posix_spawnp will search PATH
            executablePath = argv0
        }

        // Build new arguments with --nofork to prevent infinite spawn loop
        var newArgs = ["--nofork"]
        for i in 1..<args.count {
            if args[i] != "--nofork" {  // Don't duplicate --nofork
                newArgs.append(args[i])
            }
        }

        // Convert to C strings for posix_spawnp
        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(executablePath)]
        for arg in newArgs {
            cArgs.append(strdup(arg))
        }
        cArgs.append(nil)

        // Helper to cleanup cArgs
        func cleanupCArgs() {
            for ptr in cArgs where ptr != nil {
                free(ptr)
            }
        }

        // Setup file actions to redirect stdin/stdout/stderr to /dev/null
        var fileActions: posix_spawn_file_actions_t?
        var spawnAttr: posix_spawnattr_t?
        var fileActionsInitialized = false
        var spawnAttrInitialized = false
        var setupOk = true

        var err = posix_spawn_file_actions_init(&fileActions)
        if err != 0 {
            print("posix_spawn_file_actions_init failed: \(String(cString: strerror(err)))")
            setupOk = false
        } else {
            fileActionsInitialized = true
        }

        if setupOk {
            err = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            if err != 0 {
                print("posix_spawn_file_actions_addopen(stdin) failed: \(String(cString: strerror(err)))")
                setupOk = false
            }
        }
        if setupOk {
            err = posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
            if err != 0 {
                print("posix_spawn_file_actions_addopen(stdout) failed: \(String(cString: strerror(err)))")
                setupOk = false
            }
        }
        if setupOk {
            err = posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
            if err != 0 {
                print("posix_spawn_file_actions_addopen(stderr) failed: \(String(cString: strerror(err)))")
                setupOk = false
            }
        }

        // Setup spawn attributes to start new session (like setsid)
        if setupOk {
            err = posix_spawnattr_init(&spawnAttr)
            if err != 0 {
                print("posix_spawnattr_init failed: \(String(cString: strerror(err)))")
                setupOk = false
            } else {
                spawnAttrInitialized = true
            }
        }
        if setupOk {
            err = posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_SETSID))
            if err != 0 {
                print("posix_spawnattr_setflags failed: \(String(cString: strerror(err)))")
                setupOk = false
            }
        }

        // Helper to cleanup posix_spawn resources
        func cleanupSpawnResources() {
            if fileActionsInitialized {
                let destroyErr = posix_spawn_file_actions_destroy(&fileActions)
                if destroyErr != 0 {
                    print("posix_spawn_file_actions_destroy failed: \(String(cString: strerror(destroyErr)))")
                }
            }
            if spawnAttrInitialized {
                let destroyErr = posix_spawnattr_destroy(&spawnAttr)
                if destroyErr != 0 {
                    print("posix_spawnattr_destroy failed: \(String(cString: strerror(destroyErr)))")
                }
            }
        }

        if setupOk {
            // Save original cwd to restore on failure
            let originalCwd = FileManager.default.currentDirectoryPath

            // Change to $HOME before spawn
            if let home = ProcessInfo.processInfo.environment["HOME"] {
                if !FileManager.default.changeCurrentDirectoryPath(home) {
                    print("Warning: failed to chdir to $HOME, continuing with current directory")
                }
            }

            var pid: pid_t = 0
            let result = posix_spawnp(&pid, executablePath, &fileActions, &spawnAttr, &cArgs, environ)

            // Cleanup
            cleanupSpawnResources()
            cleanupCArgs()

            if result == 0 {
                // Spawn succeeded - parent exits, new process runs independently
                exit(0)
            } else {
                // Spawn failed - restore original cwd and continue in current process
                if !FileManager.default.changeCurrentDirectoryPath(originalCwd) {
                    print("Warning: failed to restore original cwd")
                }
                let errorMsg = String(cString: strerror(result))
                print("posix_spawnp failed: \(errorMsg) (error \(result))")
            }
        } else {
            // Setup failed - cleanup and continue in current process
            cleanupSpawnResources()
            cleanupCArgs()
        }
    }
}
// --nofork mode or no cache: keep current directory, stay attached to terminal

// Configure logging before anything else.
// CLI --log takes precedence over config file. Iterate zonvieArgs so
// a post-`--` `--log` token (meant for nvim) is not consumed by zonvie.
var cliLogPath: String? = nil
for i in 0..<zonvieArgs.count {
    if zonvieArgs[i] == "--log" && i + 1 < zonvieArgs.count {
        cliLogPath = zonvieArgs[i + 1]
        break
    }
}

let config = ZonvieConfig.shared
if let logPath = cliLogPath {
    ZonvieCore.configureLogging(enabled: true, filePath: logPath, perfOnly: config.log.perfOnly)
} else if config.log.enabled {
    ZonvieCore.configureLogging(enabled: true, filePath: config.log.path, perfOnly: config.log.perfOnly)
} else {
    ZonvieCore.configureLogging(enabled: false, filePath: nil, perfOnly: config.log.perfOnly)
}

// Validate --nvim path (reject quote characters that break shell/Zig parser quoting)
if let nvim = cliNvimPath, nvim.contains("'") || nvim.contains("\"") {
    fputs("Error: --nvim path must not contain quote characters (' or \")\n", stderr)
    cliNvimPath = nil
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
// Force any pending UserDefaults writes (e.g. NSWindow frame autosave) to
// disk before Darwin.exit kills the process — the C exit() path skips
// cfprefsd's natural drain that NSApp.terminate() would otherwise allow.
UserDefaults.standard.synchronize()
Darwin.exit(ZonvieCore.getExitCode())

