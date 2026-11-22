import Foundation
import Logging

/// Persistent JSON-lines bridge to a local Python `misaki` G2P worker.
/// Runs blocking pipe I/O on a dedicated serial DispatchQueue so Swift's
/// cooperative concurrency pool is never blocked.
final class MisakiPhonemizer: @unchecked Sendable {
    private let pythonPath: String
    private let workerPath: String
    private let ioQueue = DispatchQueue(label: "MisakiPhonemizer.io")

    // All mutable state below is accessed exclusively on `ioQueue`.
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readBuffer = Data()
    private var logger: Logger = {
        var l = Logger(label: "MisakiPhonemizer")
        l.logLevel = .notice
        return l
    }()

    init(
        pythonPath: String? = nil,
        workerPath: String? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = ProcessInfo.processInfo.environment
        self.pythonPath =
            pythonPath
            ?? env["MISAKI_PYTHON"]
            ?? "\(home)/.local/share/speech-server-misaki/venv/bin/python"
        self.workerPath =
            workerPath
            ?? env["MISAKI_WORKER"]
            ?? "\(home)/.local/share/speech-server-misaki/misaki_worker.py"
    }

    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath)
            && FileManager.default.fileExists(atPath: workerPath)
    }

    func warmUp() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    try self.ensureRunning()
                    continuation.resume()
                }
                catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func phonemize(_ text: String, british: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    let result = try self.phonemizeSync(text, british: british)
                    continuation.resume(returning: result)
                }
                catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func phonemizeSync(_ text: String, british: Bool) throws -> String {
        try ensureRunning()
        guard let stdinHandle else {
            throw MisakiError.notRunning
        }

        let payload: [String: Any] = ["text": text, "british": british]
        var lineData = try JSONSerialization.data(withJSONObject: payload)
        lineData.append(0x0A)  // '\n'

        do {
            try stdinHandle.write(contentsOf: lineData)
            let responseLine = try readLine()
            guard
                let obj = try JSONSerialization.jsonObject(with: responseLine) as? [String: Any]
            else {
                throw MisakiError.invalidResponse
            }
            if let errorMsg = obj["error"] as? String {
                throw MisakiError.workerError(errorMsg)
            }
            guard let phonemes = obj["phonemes"] as? String else {
                throw MisakiError.invalidResponse
            }
            return phonemes
        }
        catch {
            stopProcess()
            throw error
        }
    }

    private func ensureRunning() throws {
        if let process, process.isRunning {
            return
        }
        stopProcess()

        guard isAvailable else {
            throw MisakiError.unavailable
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [workerPath]

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        // Discard stderr so an undrained pipe buffer can never deadlock the worker.
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading
        self.readBuffer.removeAll(keepingCapacity: false)

        let readyLine = try readLine()
        guard
            let obj = try? JSONSerialization.jsonObject(with: readyLine) as? [String: Any],
            obj["ready"] as? Bool == true
        else {
            stopProcess()
            throw MisakiError.startupFailed
        }
        logger.notice("Misaki G2P worker ready")
    }

    private func readLine() throws -> Data {
        guard let stdoutHandle else {
            throw MisakiError.notRunning
        }
        while true {
            if let newlineIdx = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<newlineIdx])
                readBuffer.removeSubrange(...newlineIdx)
                return line
            }
            let chunk = stdoutHandle.availableData
            if chunk.isEmpty {
                throw MisakiError.unexpectedEOF
            }
            readBuffer.append(chunk)
        }
    }

    private func stopProcess() {
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        readBuffer.removeAll(keepingCapacity: false)
    }
}

enum MisakiError: Error, CustomStringConvertible {
    case unavailable
    case notRunning
    case startupFailed
    case unexpectedEOF
    case invalidResponse
    case workerError(String)

    var description: String {
        switch self {
        case .unavailable:
            return "Misaki Python worker is not installed."
        case .notRunning:
            return "Misaki worker process is not running."
        case .startupFailed:
            return "Misaki worker failed to signal readiness."
        case .unexpectedEOF:
            return "Misaki worker closed stdout unexpectedly."
        case .invalidResponse:
            return "Invalid JSON response from Misaki worker."
        case .workerError(let msg):
            return "Misaki worker error: \(msg)"
        }
    }
}
