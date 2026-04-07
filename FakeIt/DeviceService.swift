import Foundation

extension Notification.Name {
    /// Posted when FakeIt could not keep `remote tunneld` running (check `userInfo["reason"]`).
    static let fakeItTunneldFailed = Notification.Name("fakeItTunneldFailed")
}

struct ConnectedDevice: Identifiable, Equatable, Hashable {
    var id: String { udid }
    let name: String
    let udid: String
    /// Parsed OS version from `xctrace list devices` (e.g. 18.2); nil if unknown.
    let osVersion: OperatingSystemVersion?

    var iosMajor: Int? {
        osVersion.map { $0.majorVersion }
    }

    /// iOS 17+ uses `pymobiledevice3 developer dvt simulate-location`; older versions use the legacy `developer simulate-location` subcommand.
    var prefersDVTLocationCLI: Bool {
        guard let major = iosMajor else { return true }
        return major >= 17
    }

    static func == (lhs: ConnectedDevice, rhs: ConnectedDevice) -> Bool {
        lhs.udid == rhs.udid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(udid)
    }
}

extension ConnectedDevice {
    /// Passed to the Python bridge. If unknown, assume a recent iOS so FakeIt uses the Core Device tunnel path (iOS 17+).
    var iosVersionStringForScript: String {
        guard let v = osVersion else { return "18.0" }
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

enum DeviceService {
    struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    static func run(executable: String, arguments: [String], environment: [String: String]? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// GUI apps often inherit a tiny `PATH`, so Homebrew/pyenv Python is invisible to child processes.
    private static func subprocessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let pathPrefix = [
            "\(home)/.local/bin",
            "\(home)/.pyenv/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = pathPrefix + ":" + existing
        if env["HOME"] == nil || env["HOME"]!.isEmpty { env["HOME"] = home }
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private static func orderedPythonsWithPymobile() -> [String] {
        let venvPy = bundledVenvPythonPath
        var ordered: [String] = []
        var seen = Set<String>()
        if FileManager.default.isExecutableFile(atPath: venvPy) {
            ordered.append(venvPy)
            seen.insert(venvPy)
        }
        for p in python3CandidatePaths() where !seen.contains(p) {
            ordered.append(p)
            seen.insert(p)
        }
        let env = subprocessEnvironment()
        return ordered.filter {
            run(executable: $0, arguments: ["-c", "import pymobiledevice3"], environment: env).exitCode == 0
        }
    }

    private static func tailOfTunneldLog(maxBytes: Int = 2400) -> String {
        let url = tunneldLogFileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return "(no log yet — see \(url.path))"
        }
        let slice = data.suffix(maxBytes)
        let s = String(data: slice, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "(log not UTF-8)" : s
    }

    static func listPhysicalDevices() -> (devices: [ConnectedDevice], rawOutput: String) {
        let r = run(executable: "/usr/bin/xcrun", arguments: ["xctrace", "list", "devices"])
        let combined = r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr)
        return (parseXctraceDevices(from: combined), combined)
    }

    static func parseXctraceDevices(from output: String) -> [ConnectedDevice] {
        var devices: [ConnectedDevice] = []
        var section: String?

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("== ") && trimmed.hasSuffix(" ==") {
                section = trimmed
                continue
            }
            guard section == "== Devices ==" else { continue }
            guard !trimmed.isEmpty else { continue }

            if let d = parseDeviceLine(trimmed), !isMacName(d.name) {
                devices.append(d)
            }
        }
        return devices
    }

    private static func isMacName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("macbook") || n.contains("imac") || n.contains("mac mini") || n.contains("mac pro") { return true }
        if n.contains("mac studio") || n.hasPrefix("mac ") { return true }
        return false
    }

    /// `Name (26.3.1) (UDID)` or `Name (UDID)` for some hosts.
    private static func parseDeviceLine(_ line: String) -> ConnectedDevice? {
        let withVersion = #"^(.+?)\s+\(([\d.]+)\)\s+\(([0-9A-Fa-f-]+)\)\s*$"#
        if let regex = try? NSRegularExpression(pattern: withVersion, options: []),
           let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let nameR = Range(m.range(at: 1), in: line),
           let verR = Range(m.range(at: 2), in: line),
           let udidR = Range(m.range(at: 3), in: line) {
            let name = String(line[nameR]).trimmingCharacters(in: .whitespaces)
            let ver = String(line[verR])
            let udid = String(line[udidR])
            return ConnectedDevice(name: name, udid: udid, osVersion: parseVersion(ver))
        }

        let noVersion = #"^(.+?)\s+\(([0-9A-Fa-f-]+)\)\s*$"#
        if let regex = try? NSRegularExpression(pattern: noVersion, options: []),
           let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let nameR = Range(m.range(at: 1), in: line),
           let udidR = Range(m.range(at: 2), in: line) {
            let name = String(line[nameR]).trimmingCharacters(in: .whitespaces)
            let udid = String(line[udidR])
            if udid.count >= 20 {
                return ConnectedDevice(name: name, udid: udid, osVersion: nil)
            }
        }
        return nil
    }

    private static func parseVersion(_ s: String) -> OperatingSystemVersion? {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    // MARK: - Location injection
    //
    // Physical-device location simulation is driven by pymobiledevice3. Many Xcode builds do not ship
    // `devicectl device control simulate-location` (and `devicectl device` has no `--device` flag),
    // so relying on devicectl here fails with exit 64.
    //
    // GUI apps often inherit a minimal PATH and `/usr/bin/python3` may point at Xcode’s interpreter,
    // which does not have user-installed packages — we probe several `python3` paths for `pymobiledevice3`.

    static func injectLocation(latitude: Double, longitude: Double, device: ConnectedDevice) -> CommandResult {
        let bridge = startBridgeHoldSet(device: device, latitude: latitude, longitude: longitude)
        if bridge.exitCode == 0 { return bridge }

        if device.prefersDVTLocationCLI {
            let dvt = pymobileDVTSet(lat: latitude, lon: longitude, udid: device.udid)
            if dvt.exitCode == 0 { return dvt }
            let legacy = pymobileLegacySet(lat: latitude, lon: longitude, udid: device.udid)
            if legacy.exitCode == 0 { return legacy }
            return mergeBridgeAndCLI(bridge: bridge, first: dvt, second: legacy, topic: "Set simulated location")
        } else {
            let legacy = pymobileLegacySet(lat: latitude, lon: longitude, udid: device.udid)
            if legacy.exitCode == 0 { return legacy }
            let dvt = pymobileDVTSet(lat: latitude, lon: longitude, udid: device.udid)
            if dvt.exitCode == 0 { return dvt }
            return mergeBridgeAndCLI(bridge: bridge, first: legacy, second: dvt, topic: "Set simulated location")
        }
    }

    static func resetLocation(device: ConnectedDevice) -> CommandResult {
        let bridge = runBridgeClear(device: device)
        if bridge.exitCode == 0 { return bridge }

        if device.prefersDVTLocationCLI {
            let dvt = pymobileDVTClear(udid: device.udid)
            if dvt.exitCode == 0 { return dvt }
            let legacy = pymobileLegacyClear(udid: device.udid)
            if legacy.exitCode == 0 { return legacy }
            return mergeBridgeAndCLI(bridge: bridge, first: dvt, second: legacy, topic: "Reset simulated location")
        } else {
            let legacy = pymobileLegacyClear(udid: device.udid)
            if legacy.exitCode == 0 { return legacy }
            let dvt = pymobileDVTClear(udid: device.udid)
            if dvt.exitCode == 0 { return dvt }
            return mergeBridgeAndCLI(bridge: bridge, first: legacy, second: dvt, topic: "Reset simulated location")
        }
    }

    // MARK: - Python location bridge (Core Device tunnel + DVT, process stays alive)

    private static let holdLock = NSLock()
    private static var locationHoldProcess: Process?

    /// Stops the background bridge that keeps DVT location simulation active (call before clear or new spoof).
    static func stopLocationHoldProcess() {
        holdLock.lock()
        defer { holdLock.unlock() }
        guard let proc = locationHoldProcess else { return }
        if proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        locationHoldProcess = nil
    }

    private static func bridgeScriptPath() -> String? {
        Bundle.main.url(forResource: "fakeit_location_bridge", withExtension: "py")?.path
    }

    private static func pythonExecutableForPymobile() -> String? {
        let env = subprocessEnvironment()
        let venvPy = bundledVenvPythonPath
        if FileManager.default.isExecutableFile(atPath: venvPy),
           run(executable: venvPy, arguments: ["-c", "import pymobiledevice3"], environment: env).exitCode == 0 {
            return venvPy
        }
        for py in python3CandidatePaths() {
            if run(executable: py, arguments: ["-c", "import pymobiledevice3"], environment: env).exitCode == 0 {
                return py
            }
        }
        if prepareBundledVenvIfNeeded() == nil,
           FileManager.default.isExecutableFile(atPath: venvPy),
           run(executable: venvPy, arguments: ["-c", "import pymobiledevice3"], environment: env).exitCode == 0 {
            return venvPy
        }
        return nil
    }

    private static func startBridgeHoldSet(device: ConnectedDevice, latitude: Double, longitude: Double) -> CommandResult {
        stopLocationHoldProcess()

        guard let pyPath = pythonExecutableForPymobile() else {
            return CommandResult(exitCode: 1, stdout: "", stderr: "No Python with pymobiledevice3 (venv or Homebrew).")
        }
        guard let script = bridgeScriptPath() else {
            return CommandResult(exitCode: 1, stdout: "", stderr: "fakeit_location_bridge.py not found in app bundle.")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pyPath)
        proc.arguments = [
            script,
            "hold-set",
            device.udid,
            device.iosVersionStringForScript,
            String(latitude),
            String(longitude)
        ]
        proc.environment = subprocessEnvironment()
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if let stdin = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null")) {
            proc.standardInput = stdin
        }
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = errPipe

        do {
            try proc.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        holdLock.lock()
        locationHoldProcess = proc
        holdLock.unlock()

        Thread.sleep(forTimeInterval: 1.35)

        if proc.isRunning {
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }

        holdLock.lock()
        locationHoldProcess = nil
        holdLock.unlock()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Location bridge exited immediately."
        return CommandResult(exitCode: 1, stdout: "", stderr: "Location bridge failed:\n\(msg)")
    }

    private static func runBridgeClear(device: ConnectedDevice) -> CommandResult {
        stopLocationHoldProcess()

        guard let pyPath = pythonExecutableForPymobile() else {
            return CommandResult(exitCode: 1, stdout: "", stderr: "")
        }
        guard let script = bridgeScriptPath() else {
            return CommandResult(exitCode: 1, stdout: "", stderr: "")
        }

        let r = run(
            executable: pyPath,
            arguments: [script, "clear", device.udid, device.iosVersionStringForScript]
        )
        return sanitizePymobileResult(r)
    }

    private static func mergeBridgeAndCLI(bridge: CommandResult, first: CommandResult, second: CommandResult, topic: String) -> CommandResult {
        let hint = mergeTwoAttempts(first: first, second: second, topic: topic).stderr
        let bridgeMsg = bridge.stderr.isEmpty ? "(bridge failed to start — see stderr above)" : bridge.stderr
        return CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: """
            \(topic): location bridge did not stay running:
            \(bridgeMsg)

            CLI fallback also failed:
            \(hint)
            """
        )
    }

    private static func pymobileDVTSet(lat: Double, lon: Double, udid: String) -> CommandResult {
        // iOS 17+ DVT services usually need CoreDevice tunneling; pymobiledevice3 may still exit 0 while logging ERROR if the tunnel is missing.
        let tunneled = runPymobileDevice3(arguments: [
            "developer", "dvt", "simulate-location", "set",
            "--udid", udid,
            "--tunnel", udid,
            "--",
            String(lat), String(lon)
        ])
        if tunneled.exitCode == 0 { return tunneled }
        return runPymobileDevice3(arguments: [
            "developer", "dvt", "simulate-location", "set",
            "--udid", udid,
            "--",
            String(lat), String(lon)
        ])
    }

    private static func pymobileLegacySet(lat: Double, lon: Double, udid: String) -> CommandResult {
        runPymobileDevice3(arguments: [
            "developer", "simulate-location", "set",
            "--udid", udid,
            "--",
            String(lat), String(lon)
        ])
    }

    private static func pymobileDVTClear(udid: String) -> CommandResult {
        let tunneled = runPymobileDevice3(arguments: [
            "developer", "dvt", "simulate-location", "clear",
            "--udid", udid,
            "--tunnel", udid
        ])
        if tunneled.exitCode == 0 { return tunneled }
        return runPymobileDevice3(arguments: [
            "developer", "dvt", "simulate-location", "clear",
            "--udid", udid
        ])
    }

    private static func pymobileLegacyClear(udid: String) -> CommandResult {
        runPymobileDevice3(arguments: [
            "developer", "simulate-location", "clear",
            "--udid", udid
        ])
    }

    private static var fakeItSupportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return root.appendingPathComponent("FakeIt", isDirectory: true)
    }

    /// Dedicated venv so `pip install pymobiledevice3` works even when Homebrew Python is PEP 668–managed.
    private static var bundledVenvPythonPath: String {
        fakeItSupportDirectory.appendingPathComponent("venv/bin/python3", isDirectory: false).path
    }

    /// Ordered `python3` paths: Homebrew / pyenv / PATH / system (last).
    private static func python3CandidatePaths() -> [String] {
        var raw: [String] = []
        let home = NSHomeDirectory()

        raw.append("\(home)/.local/bin/python3")
        raw.append("\(home)/.pyenv/shims/python3")

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let d = String(dir).trimmingCharacters(in: .whitespaces)
                guard !d.isEmpty else { continue }
                raw.append(URL(fileURLWithPath: d, isDirectory: true).appendingPathComponent("python3").path)
            }
        }

        raw.append("/opt/homebrew/bin/python3")
        raw.append("/usr/local/bin/python3")
        raw.append("/Library/Frameworks/Python.framework/Versions/Current/bin/python3")
        raw.append("/usr/bin/python3")

        var seen = Set<String>()
        var out: [String] = []
        for p in raw where !seen.contains(p) {
            seen.insert(p)
            guard FileManager.default.isExecutableFile(atPath: p) else { continue }
            out.append(p)
        }
        return out
    }

    /// Creates `~/Library/Application Support/FakeIt/venv` and installs pymobiledevice3 (needs network once).
    private static func prepareBundledVenvIfNeeded() -> CommandResult? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fakeItSupportDirectory, withIntermediateDirectories: true)
        } catch {
            return CommandResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        let venvPy = bundledVenvPythonPath
        if fm.isExecutableFile(atPath: venvPy) {
            let probe = run(executable: venvPy, arguments: ["-c", "import pymobiledevice3"])
            if probe.exitCode == 0 { return nil }
        }

        let seeds = python3CandidatePaths()
        guard let seedPy = seeds.first else {
            return CommandResult(
                exitCode: 1,
                stdout: "",
                stderr: "No python3 found to create FakeIt’s helper environment. Install Python 3 (e.g. brew install python)."
            )
        }

        let venvDir = fakeItSupportDirectory.appendingPathComponent("venv", isDirectory: true).path
        if !fm.fileExists(atPath: venvDir) {
            let mk = run(executable: seedPy, arguments: ["-m", "venv", venvDir])
            if mk.exitCode != 0 {
                let detail = (mk.stderr + mk.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                return CommandResult(
                    exitCode: mk.exitCode,
                    stdout: mk.stdout,
                    stderr: "Could not create venv with \(seedPy). \(detail)"
                )
            }
        }

        guard fm.isExecutableFile(atPath: venvPy) else {
            return CommandResult(exitCode: 1, stdout: "", stderr: "venv python missing at \(venvPy)")
        }

        let pipSelf = run(executable: venvPy, arguments: ["-m", "pip", "install", "-q", "--upgrade", "pip"])
        if pipSelf.exitCode != 0 {
            let detail = (pipSelf.stderr + pipSelf.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandResult(exitCode: pipSelf.exitCode, stdout: pipSelf.stdout, stderr: "pip upgrade failed: \(detail)")
        }

        let inst = run(executable: venvPy, arguments: ["-m", "pip", "install", "-q", "pymobiledevice3>=9.0"])
        if inst.exitCode != 0 {
            let detail = (inst.stderr + inst.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandResult(
                exitCode: inst.exitCode,
                stdout: inst.stdout,
                stderr: "pip install pymobiledevice3 failed (network required once): \(detail)"
            )
        }
        return nil
    }

    private static func runPymobileDevice3(arguments pymobileArgs: [String]) -> CommandResult {
        let venvPy = bundledVenvPythonPath
        var ordered: [String] = []
        var seen = Set<String>()
        if FileManager.default.isExecutableFile(atPath: venvPy) {
            ordered.append(venvPy)
            seen.insert(venvPy)
        }
        for p in python3CandidatePaths() where !seen.contains(p) {
            seen.insert(p)
            ordered.append(p)
        }

        if ordered.isEmpty {
            return CommandResult(
                exitCode: 1,
                stdout: "",
                stderr: "No executable python3 found. Install Python 3 (e.g. Homebrew)."
            )
        }

        for py in ordered {
            let probe = run(executable: py, arguments: ["-c", "import pymobiledevice3"])
            if probe.exitCode == 0 {
                let raw = run(executable: py, arguments: ["-m", "pymobiledevice3"] + pymobileArgs)
                return sanitizePymobileResult(raw)
            }
        }

        if let setupError = prepareBundledVenvIfNeeded() {
            return setupError
        }

        let probeVenv = run(executable: venvPy, arguments: ["-c", "import pymobiledevice3"])
        if probeVenv.exitCode == 0 {
            let raw = run(executable: venvPy, arguments: ["-m", "pymobiledevice3"] + pymobileArgs)
            return sanitizePymobileResult(raw)
        }

        let tail = (probeVenv.stderr + probeVenv.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "pymobiledevice3 is still unavailable after automatic setup.\n\(tail)"
        )
    }

    private static func mergeTwoAttempts(first: CommandResult, second: CommandResult, topic: String) -> CommandResult {
        let hint = """
        Hints: USB + Trust · Developer Mode · mount Developer Disk Image (Xcode → Devices). \
        iOS 17+ often needs administrator privileges for the Core Device tunnel: quit FakeIt and run \
        `sudo /path/to/FakeIt.app/Contents/MacOS/FakeIt` once, or use `sudo \(bundledVenvPythonPath) -m pymobiledevice3 remote tunneld` while testing.
        """
        let msg = """
        \(topic) failed (pymobiledevice3).
        --- first attempt (exit \(first.exitCode)) ---
        \(first.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        \(first.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        --- second attempt (exit \(second.exitCode)) ---
        \(second.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        \(second.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        \(hint)
        """
        let code = second.exitCode != 0 ? second.exitCode : first.exitCode
        return CommandResult(exitCode: code, stdout: "", stderr: msg)
    }

    /// pymobiledevice3 often exits 0 while logging `] ERROR` to stderr; treat that as failure so the UI does not show “Spoofed”.
    private static func sanitizePymobileResult(_ r: CommandResult) -> CommandResult {
        guard r.exitCode == 0 else { return r }
        let blob = r.stderr + "\n" + r.stdout
        if pymobileOutputIndicatesFailure(blob) {
            return CommandResult(exitCode: 1, stdout: r.stdout, stderr: r.stderr)
        }
        return r
    }

    private static func pymobileOutputIndicatesFailure(_ blob: String) -> Bool {
        if blob.contains("] ERROR") { return true }
        if blob.contains("╭─ Error") { return true }
        if blob.contains("No such option:") { return true }
        if blob.contains("Device not found") { return true }
        if blob.contains("Unable to connect to Tunneld") { return true }
        return false
    }

    // MARK: - Automatic `remote tunneld` (iOS 17+ USB tunnel + phone pairing prompt)

    private static let tunneldQueue = DispatchQueue(label: "com.fakeit.tunneld", qos: .utility)
    private static let tunneldStateLock = NSLock()
    private static var tunneldChildProcess: Process?
    private static var fakeItOwnsTunneldProcess = false

    private static var tunneldLogFileURL: URL {
        fakeItSupportDirectory.appendingPathComponent("tunneld.log", isDirectory: false)
    }

    /// True if something is answering on pymobiledevice3’s default tunneld HTTP port (49151).
    private static func tunneldHTTPEndpointResponds() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:49151/") else { return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.4
        cfg.timeoutIntervalForResource = 0.45
        URLSession(configuration: cfg).dataTask(with: url) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200 ..< 500).contains(http.statusCode) {
                ok = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 0.5)
        return ok
    }

    /// Starts `python3 -m pymobiledevice3 remote tunneld` from FakeIt’s venv when an iOS 17+ device may be used.
    /// Safe to call often (USB poll): no-op if tunneld is already up or our child is running.
    static func ensureTunneldRunningForIOS17Support() {
        tunneldQueue.async { ensureTunneldRunningImpl() }
    }

    /// Terminates tunneld only if FakeIt started it (leaves a manually launched tunneld alone).
    static func stopTunneldIfStartedByFakeIt() {
        tunneldQueue.async { stopTunneldIfStartedByFakeItOnQueue() }
    }

    /// Synchronous stop for app termination (waits for the tunneld queue).
    static func stopTunneldIfStartedByFakeItSync() {
        tunneldQueue.sync { stopTunneldIfStartedByFakeItOnQueue() }
    }

    private static func stopTunneldIfStartedByFakeItOnQueue() {
        tunneldStateLock.lock()
        defer { tunneldStateLock.unlock() }
        guard fakeItOwnsTunneldProcess, let proc = tunneldChildProcess else { return }
        if proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        tunneldChildProcess = nil
        fakeItOwnsTunneldProcess = false
    }

    private static func ensureTunneldRunningImpl() {
        if tunneldHTTPEndpointResponds() { return }

        tunneldStateLock.lock()
        if let existing = tunneldChildProcess, existing.isRunning {
            tunneldStateLock.unlock()
            return
        }
        tunneldStateLock.unlock()

        if tunneldHTTPEndpointResponds() { return }

        _ = prepareBundledVenvIfNeeded()
        let candidates = orderedPythonsWithPymobile()
        let logURL = tunneldLogFileURL
        let logPath = logURL.path

        if candidates.isEmpty {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .fakeItTunneldFailed,
                    object: nil,
                    userInfo: ["reason": """
                    Cannot start tunneld: no Python with pymobiledevice3 found. \
                    Install once: pip3 install -r requirements.txt (or pip3 install 'pymobiledevice3>=9'). \
                    Then reopen FakeIt.
                    """]
                )
            }
            return
        }

        var lastTriedPython = candidates.first ?? "/usr/bin/python3"
        for pyPath in candidates {
            lastTriedPython = pyPath
            if tunneldHTTPEndpointResponds() { return }

            tunneldStateLock.lock()
            if let existing = tunneldChildProcess, existing.isRunning {
                tunneldStateLock.unlock()
                return
            }
            tunneldStateLock.unlock()

            FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
            guard let childLog = try? FileHandle(forWritingTo: logURL) else { continue }
            try? childLog.seekToEnd()
            let stamp = "\n\n--- FakeIt tunneld \(ISO8601DateFormatter().string(from: Date())) ---\npython: \(pyPath)\n"
            if let data = stamp.data(using: .utf8) {
                try? childLog.write(contentsOf: data)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pyPath)
            proc.arguments = ["-u", "-m", "pymobiledevice3", "remote", "tunneld"]
            proc.environment = subprocessEnvironment()
            proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            if let stdin = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null")) {
                proc.standardInput = stdin
            }
            proc.standardOutput = childLog
            proc.standardError = childLog

            let procRef = proc
            let logURLCapture = logURL
            proc.terminationHandler = { p in
                tunneldStateLock.lock()
                defer { tunneldStateLock.unlock() }
                if tunneldChildProcess === p {
                    tunneldChildProcess = nil
                    fakeItOwnsTunneldProcess = false
                }
                if let line = "\n--- tunneld exited (status \(p.terminationStatus)) ---\n".data(using: .utf8),
                   let h = try? FileHandle(forWritingTo: logURLCapture) {
                    try? h.seekToEnd()
                    try? h.write(contentsOf: line)
                    try? h.close()
                }
                try? childLog.close()
            }

            tunneldStateLock.lock()
            if tunneldHTTPEndpointResponds() {
                tunneldStateLock.unlock()
                try? childLog.close()
                continue
            }
            if let existing = tunneldChildProcess, existing.isRunning {
                tunneldStateLock.unlock()
                try? childLog.close()
                return
            }

            do {
                try proc.run()
                tunneldChildProcess = procRef
                fakeItOwnsTunneldProcess = true
            } catch {
                tunneldStateLock.unlock()
                try? childLog.close()
                continue
            }
            tunneldStateLock.unlock()

            for delay in [0.5, 0.7, 1.0, 1.4, 1.8] {
                Thread.sleep(forTimeInterval: delay)
                if tunneldHTTPEndpointResponds() { return }
                if !procRef.isRunning { break }
            }

            if tunneldHTTPEndpointResponds() { return }

            tunneldStateLock.lock()
            let ownedHere = tunneldChildProcess === procRef
            if ownedHere {
                tunneldChildProcess = nil
                fakeItOwnsTunneldProcess = false
            }
            tunneldStateLock.unlock()
            if ownedHere, procRef.isRunning {
                procRef.terminate()
                procRef.waitUntilExit()
            }
        }

        let tail = tailOfTunneldLog()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .fakeItTunneldFailed,
                object: nil,
                userInfo: ["reason": """
                tunneld could not be started automatically (needed for iOS 17+).

                In Terminal run (use your Mac password when asked):
                sudo \(lastTriedPython) -m pymobiledevice3 remote tunneld

                Leave that window open, unlock the iPhone, approve pairing, then try Simulate again.

                Full log file:
                \(logPath)

                Last log lines:
                \(tail)
                """]
            )
        }
    }
}
