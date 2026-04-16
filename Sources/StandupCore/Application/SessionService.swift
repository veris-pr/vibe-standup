/// Application service: orchestrates session lifecycle.
///
/// This is the use-case layer — coordinates domain objects and infrastructure.

import Foundation

public final class SessionService: @unchecked Sendable {
    private let config: StandupConfig
    private let repository: SessionRepository
    private var activeSession: Session?
    private var captureEngine: AudioCapturePort?

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
        try repository.save(session)

        let engine = AudioCaptureFactory.create(
            source: captureSource,
            sessionDirectory: sessionDir,
            micChain: micChain,
            systemChain: systemChain,
            virtualDeviceName: virtualDeviceName
        )
        try await engine.start()

        self.captureEngine = engine
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

        session.status = .processing
        session.endTime = Date()
        try repository.update(session)

        activeSession = nil
        return session
    }

    public func markComplete(sessionId: String) throws {
        guard var session = try repository.find(id: sessionId) else {
            throw SessionError.notFound(sessionId)
        }
        session.status = .complete
        try repository.update(session)
    }

    public func markFailed(sessionId: String) throws {
        guard var session = try repository.find(id: sessionId) else {
            throw SessionError.notFound(sessionId)
        }
        session.status = .failed
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
