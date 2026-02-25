//
//  PMD3Helper.swift
//  LocationSimulator
//
//  Helper class that wraps pymobiledevice3 CLI for iOS 17+ location simulation.
//  pymobiledevice3 supports the new RemoteXPC/tunneld protocol that Apple requires
//  for developer services on iOS 17 and later.
//

import Foundation
import CoreLocation
import CLogger

/// Helper class to interact with pymobiledevice3 for iOS 17+ devices.
///
/// Architecture:
/// - iOS 17+ requires a RemoteXPC tunnel for developer services
/// - `tunneld` must run as root (sudo) to create the TUN network interface
/// - We use `osascript` to request admin privileges for tunneld startup
/// - Location simulation uses the DVT instruments protocol (`developer dvt simulate-location`)
///   which connects through the tunnel and stays alive as a persistent process
/// - When the location changes, the old process is killed and a new one spawned
/// - To clear the location, the process is simply killed
class PMD3Helper {

    /// Shared singleton instance
    static let shared = PMD3Helper()

    /// Path to the pymobiledevice3 CLI binary
    private let pmd3Path: String

    /// Whether pymobiledevice3 is available on this system
    private(set) var isAvailable: Bool = false

    /// Whether tunneld has been started/verified this session
    private var tunneldReady: Bool = false

    /// The currently running DVT simulate-location process (must stay alive to maintain simulation)
    private var activeSimulationProcess: Process?

    /// Serial queue for managing the simulation process lifecycle
    private let processQueue = DispatchQueue(label: "com.locationsimulator.pmd3helper")

    /// The minimum iOS major version that requires pymobiledevice3 (17+)
    static let minimumRequiredVersion: Int = 17

    private init() {
        self.pmd3Path = PMD3Helper.findPMD3Path()
        self.isAvailable = !self.pmd3Path.isEmpty && FileManager.default.fileExists(atPath: self.pmd3Path)
        if self.isAvailable {
            logInfo("PMD3Helper: Found pymobiledevice3 at \(self.pmd3Path)")
        } else {
            logError("PMD3Helper: pymobiledevice3 not found")
        }
    }

    /// Check if a device requires pymobiledevice3 (iOS 17+)
    static func deviceRequiresPMD3(_ majorVersion: Int?) -> Bool {
        guard let major = majorVersion else { return false }
        return major >= minimumRequiredVersion
    }

    // MARK: - Binary Discovery

    /// Find the pymobiledevice3 CLI binary
    private static func findPMD3Path() -> String {
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/pymobiledevice3",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/pymobiledevice3",
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3"
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback: try to find via which
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-l", "-c", "which pymobiledevice3"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {
            logError("PMD3Helper: Failed to find pymobiledevice3: \(error)")
        }

        return ""
    }

    // MARK: - Tunnel Management

    /// Ensure tunneld is running. If not, start it with sudo via osascript.
    /// This will prompt the user for their admin password if tunneld isn't already running.
    /// - Returns: true if tunneld is running (or was started successfully)
    func ensureTunneld() -> Bool {
        if tunneldReady && isTunneldRunning() {
            return true
        }

        if isTunneldRunning() {
            logInfo("PMD3Helper: tunneld is already running")
            tunneldReady = true
            return true
        }

        logInfo("PMD3Helper: Starting tunneld with admin privileges...")

        // Use osascript to run tunneld with sudo — this prompts the user for their password
        let script = """
        do shell script "\(pmd3Path) remote tunneld -d" with administrator privileges
        """

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? "unknown"
                logError("PMD3Helper: Failed to start tunneld: \(stderr)")
                return false
            }
        } catch {
            logError("PMD3Helper: Failed to launch tunneld: \(error)")
            return false
        }

        // Wait for tunneld to become ready (up to 15 seconds)
        logInfo("PMD3Helper: Waiting for tunneld to become ready...")
        for i in 0..<30 {
            Thread.sleep(forTimeInterval: 0.5)
            if isTunneldRunning() {
                logInfo("PMD3Helper: tunneld is ready (waited \(Double(i + 1) * 0.5)s)")
                tunneldReady = true
                return true
            }
        }

        logError("PMD3Helper: tunneld did not start within 15 seconds")
        return false
    }

    /// Check if tunneld is already running by checking the process list
    func isTunneldRunning() -> Bool {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", "pgrep -f 'pymobiledevice3.*tunneld' > /dev/null 2>&1"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Location Simulation (DVT Instruments Protocol)

    /// Set a simulated location on the device using pymobiledevice3's DVT instruments protocol.
    ///
    /// This launches `pymobiledevice3 developer dvt simulate-location set` as a persistent process.
    /// The DVT version keeps a connection open to the device — location simulation stays active
    /// only while the process is alive. When a new location is set, the old process is killed first.
    ///
    /// - Parameters:
    ///   - location: The coordinate to simulate
    ///   - udid: The device UDID
    /// - Returns: true on success, false on failure
    func simulateLocation(_ location: CLLocationCoordinate2D, udid: String) -> Bool {
        guard isAvailable else {
            logError("PMD3Helper: pymobiledevice3 is not available")
            return false
        }

        guard tunneldReady || ensureTunneld() else {
            logError("PMD3Helper: Cannot simulate location — tunneld is not running")
            return false
        }

        // Kill existing simulation process (if any) before starting a new one
        killActiveSimulation()

        logInfo("PMD3Helper: Setting location to \(location.latitude), \(location.longitude) for device \(udid)")

        let task = Process()
        task.launchPath = pmd3Path
        task.arguments = [
            "developer", "dvt", "simulate-location", "set",
            "--tunnel", udid,
            "--",   // separator so negative coordinates aren't parsed as flags
            String(location.latitude),
            String(location.longitude)
        ]

        let stderrPipe = Pipe()
        task.standardOutput = Pipe()  // suppress stdout
        task.standardError = stderrPipe

        // Set up PATH
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        task.environment = env

        do {
            try task.run()
        } catch {
            logError("PMD3Helper: Failed to launch DVT simulate-location: \(error)")
            return false
        }

        // Wait briefly for the process to connect and start simulating
        // The DVT command prints "Press Ctrl+C..." once it's ready
        Thread.sleep(forTimeInterval: 2.0)

        if !task.isRunning {
            // Process exited early — read stderr for error details
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            logError("PMD3Helper: DVT simulate-location exited early (code \(task.terminationStatus)): \(stderr)")
            return false
        }

        logInfo("PMD3Helper: Location simulation active (PID \(task.processIdentifier))")

        processQueue.sync {
            self.activeSimulationProcess = task
        }

        return true
    }

    /// Clear the simulated location by killing the active DVT simulation process.
    /// - Parameter udid: The device UDID (for logging)
    /// - Returns: true on success, false on failure
    func disableSimulation(udid: String) -> Bool {
        logInfo("PMD3Helper: Clearing simulated location for device \(udid)")
        killActiveSimulation()
        return true
    }

    /// Kill the active simulation process if one is running.
    private func killActiveSimulation() {
        processQueue.sync {
            guard let process = self.activeSimulationProcess else { return }
            if process.isRunning {
                logInfo("PMD3Helper: Killing active simulation process (PID \(process.processIdentifier))")
                process.terminate()
                // Give it a moment to clean up, then force kill if needed
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    if process.isRunning {
                        process.interrupt()
                    }
                }
            }
            self.activeSimulationProcess = nil
        }
    }

    deinit {
        killActiveSimulation()
    }
}
