/// Application service: orchestrates session lifecycle.
///
/// This is the use-case layer — coordinates domain objects and infrastructure.

import Foundation

public final class SessionService: @unchecked Sendable {
    // SAFETY: @unchecked Sendable — called from CLI main thread sequentially.
    // No concurrent access to mutable state (activeSession, captureEngine).
    private let config: StandupConfig
    private let repository: SessionRepository
    private var activeSession: Session?
    private var captureEngine: AudioCapturePort?
    private var activeLiveChains: (mic: LivePluginChain, system: LivePluginChain)?

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

        try session.markProcessing()
        try repository.update(session)

        activeSession = nil
        return session
    }

    public func markComplete(sessionId: String) throws {
        guard var session = try repository.find(id: sessionId) else {
            throw SessionError.notFound(sessionId)
        }
        try session.markComplete()
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

    public func getSession(id: String) throws -> Session? {
        try repository.find(id: id)
    }

    public var currentSession: Session? { activeSession }
}
