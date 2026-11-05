import Foundation
import Mockable

/// The Android Debug Bridge on this Mac: run it to completion, or start
/// something on a device and leave it running (the scrcpy server).
@Mockable
protocol Adb: Sendable {
    /// Run `adb <arguments>` and return its stdout. Throws
    /// `AndroidError.adbFailed` on a non-zero exit or a timeout.
    func run(_ arguments: [String]) throws -> Data

    /// Start `adb <arguments>` and keep it running. `onOutput` gets its
    /// stdout and stderr; `onExit` fires once with the exit status.
    func spawn(
        _ arguments: [String],
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any AdbProcess
}

/// A long-running adb child.
@Mockable
protocol AdbProcess: AnyObject, Sendable {
    func terminate()
}

/// `adb` as a `Foundation.Process`. Thin on purpose: every decision
/// (what to run, how to read the answer) lives in the callers, which
/// are tested against `MockAdb`. Integration-only.
struct HostAdb: Adb {
    let executable: String
    let timeout: TimeInterval

    init(executable: String, timeout: TimeInterval = 30) {
        self.executable = executable
        self.timeout = timeout
    }

    func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            throw AndroidError.adbFailed("cannot launch \(executable): \(error.localizedDescription)")
        }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // stderr is drained on its own thread so a chatty adb cannot
        // fill that pipe while this one is still reading stdout.
        let errBox = Captured()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        drained.wait()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errBox.data.isEmpty ? stdout : errBox.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AndroidError.adbFailed(
                "adb \(arguments.joined(separator: " ")) exited \(process.terminationStatus)"
                + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
        return stdout
    }

    func spawn(
        _ arguments: [String],
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any AdbProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { onOutput(chunk) }
        }
        process.terminationHandler = { finished in onExit(finished.terminationStatus) }
        do { try process.run() } catch {
            throw AndroidError.adbFailed("cannot launch \(executable): \(error.localizedDescription)")
        }
        return HostAdbProcess(process)
    }

    private final class Captured: @unchecked Sendable { var data = Data() }
}

final class HostAdbProcess: AdbProcess, @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}
