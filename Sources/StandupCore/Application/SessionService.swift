/// Application service: orchestrates session lifecycle.
///
/// This is the use-case layer — coordinates domain objects and infrastructure.

import Foundation
import os

public final class SessionService: @unchecked Sendable {
    // SAFETY: @unchecked Sendable — called from CLI main thread sequentially.
    // No concurrent access to mutable state (activeSession, captureEngine).
    private let config: StandupConfig
    private let repository: SessionRepository
    private var activeSession: Session?
    private var captureEngine: AudioCapturePort?
    private var activeLiveChains: (mic: LivePluginChain, system: LivePluginChain)?
    private let captureFailure = OSAllocatedUnfairLock(initialState: Optional<SessionCaptureError>.none)

    public init(config: StandupConfig, repository: SessionRepository) {
        self.config = config
        self.repository = repository
    }

    /// Start a new capture session.
    public func startSession(
        pipelineName: String,
        micChain: LivePluginChain,
        systemChain: LivePluginChain,
        captureSource: AudioCaptureSource = .screenCapture,
        virtualDeviceName: String? = nil
    ) async throws -> Session {
        guard activeSession == nil else {
            throw SessionError.alreadyActive
        }

        captureFailure.withLock { $0 = nil }

        let id = UUID().uuidString.prefix(8).lowercased()
        let sessionDir = (config.sessionsDirectory as NSString).appendingPathComponent(String(id))
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)

        let session = Session(
            id: String(id),
            pipelineName: pipelineName,
            captureSource: captureSource,
            directoryPath: sessionDir
        )
        let engine = AudioCaptureFactory.create(
            source: captureSource,
            sessionDirectory: sessionDir,
            micChain: micChain,
            systemChain: systemChain,
            virtualDeviceName: virtualDeviceName
        )

        do {
            try await engine.start()
        } catch {
            // Clean up directory and don't leave orphan in DB
            try? FileManager.default.removeItem(atPath: sessionDir)
            throw error
        }

        // Persist only after engine starts successfully
        try repository.save(session)

        self.captureEngine = engine
        engine.delegate = self
        self.activeLiveChains = (micChain, systemChain)
        self.activeSession = session
        return session
    }

    /// Stop the active session.
    public func stopSession() async throws -> Session {
        guard var session = activeSession else {
            throw SessionError.noActiveSession
        }

        await captureEngine?.stop()
        captureEngine = nil

        // Release live plugin chains (triggers ARC cleanup)
        activeLiveChains = nil
        activeSession = nil

        if let captureFailure = takeCaptureFailure() {
            throw captureFailure
        }

        try session.markProcessing()
        try repository.update(session)

        return session
    }

    public func markComplete(sessionId: String) throws {
        guard var session = try repository.find(id: sessionId) else {
            throw SessionError.notFound(sessionId)
        }
        try session.markComplete()
        try repository.update(session)
    }

    public func markProcessing(sessionId: String) throws {
        guard var session = try repository.find(id: sessionId) else {
            throw SessionError.notFound(sessionId)
        }
        try session.markProcessing()
        try repository.update(session)
    }

    public func markFailed(sessionId: String) throws {
        guard var session = try repository.find(id: sessionId) else {
            throw SessionError.notFound(sessionId)
        }
        try session.markFailed()
        try repository.update(session)
    }

    public func listSessions() throws -> [Session] {
        try repository.listAll()
    }

    public func deleteSession(id: String) throws {
        guard let session = try repository.find(id: id) else {
            throw SessionError.notFound(id)
        }
        try? FileManager.default.removeItem(atPath: session.directoryPath)
        try repository.delete(id: id)
    }

    /// Remove only input data (audio chunks) for a session.
    public func cleanInputs(session: Session) throws {
        try? FileManager.default.removeItem(atPath: session.chunksPath)
    }

    /// Remove only pipeline output directories for a session.
    public func cleanOutputs(session: Session, stageIds: [String]) throws {
        let fm = FileManager.default
        for stageId in stageIds {
            let stagePath = session.stageOutputPath(for: stageId)
            try? fm.removeItem(atPath: stagePath)
        }
        PipelineState.remove(from: session.directoryPath)
    }

    public func getSession(id: String) throws -> Session? {
        try repository.find(id: id)
    }

    public var currentSession: Session? { activeSession }

    private func takeCaptureFailure() -> SessionCaptureError? {
        captureFailure.withLock { failure in
            let captured = failure
            failure = nil
            return captured
        }
    }
}

// MARK: - AudioCaptureDelegate

extension SessionService: AudioCaptureDelegate {
    public func didCaptureChunk(_ chunk: AudioChunk) {
        // Chunks are written to disk by ChunkWriter; nothing to do here.
    }

    public func didEncounterError(_ error: Error) {
        let shouldReport = captureFailure.withLock { failure in
            if failure == nil {
                failure = .chunkWriteFailed(error.localizedDescription)
                return true
            }
            return false
        }
        if shouldReport {
            print("⚠ Audio capture error: \(error.localizedDescription)")
        }
    }
}

public enum SessionCaptureError: Error, LocalizedError, Sendable {
    case chunkWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .chunkWriteFailed(let message):
            "Audio capture failed while writing chunks: \(message)"
        }
    }
}
