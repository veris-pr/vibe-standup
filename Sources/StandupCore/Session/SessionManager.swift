/// Session manager — owns the lifecycle of audio capture sessions.
///
/// Each session is a directory on disk containing audio chunks and pipeline artifacts.
/// Session metadata is stored in SQLite for querying.

import Foundation
import SQLite

public final class SessionManager: @unchecked Sendable {
    private let baseDirectory: String
    private let db: Connection

    // SQLite schema
    private let sessions = Table("sessions")
    private let colId = SQLite.Expression<String>("id")
    private let colStatus = SQLite.Expression<String>("status")
    private let colPipeline = SQLite.Expression<String>("pipeline")
    private let colStartTime = SQLite.Expression<Double>("start_time")
    private let colEndTime = SQLite.Expression<Double?>("end_time")
    private let colDirectory = SQLite.Expression<String>("directory")

    // Active session state
    private var activeSession: SessionInfo?
    private var captureEngine: AudioCaptureEngine?

    public init(baseDirectory: String? = nil) throws {
        let base = baseDirectory ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return (home as NSString).appendingPathComponent(".standup")
        }()
        self.baseDirectory = base

        // Ensure directories exist
        let sessionsDir = (base as NSString).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)

        // Open/create database
        let dbPath = (base as NSString).appendingPathComponent("standup.db")
        self.db = try Connection(dbPath)
        try createSchema()
    }

    private func createSchema() throws {
        try db.run(sessions.create(ifNotExists: true) { t in
            t.column(colId, primaryKey: true)
            t.column(colStatus)
            t.column(colPipeline)
            t.column(colStartTime)
            t.column(colEndTime)
            t.column(colDirectory)
        })
    }

    // MARK: - Session Lifecycle

    /// Start a new capture session.
    public func startSession(
        pipelineName: String,
        micChain: LivePluginChain,
        systemChain: LivePluginChain
    ) async throws -> SessionInfo {
        guard activeSession == nil else {
            throw SessionError.sessionAlreadyActive
        }

        let id = UUID().uuidString.prefix(8).lowercased()
        let sessionDir = (baseDirectory as NSString)
            .appendingPathComponent("sessions")
            .appending("/\(id)")
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)

        let info = SessionInfo(
            id: String(id),
            status: .active,
            pipelineName: pipelineName,
            startTime: Date(),
            directoryPath: sessionDir
        )

        // Persist to SQLite
        try db.run(sessions.insert(
            colId <- info.id,
            colStatus <- info.status.rawValue,
            colPipeline <- info.pipelineName,
            colStartTime <- info.startTime.timeIntervalSince1970,
            colDirectory <- info.directoryPath
        ))

        // Start audio capture
        let engine = AudioCaptureEngine(
            sessionDirectory: sessionDir,
            micChain: micChain,
            systemChain: systemChain
        )
        try await engine.start()

        self.captureEngine = engine
        self.activeSession = info

        return info
    }

    /// Stop the active session and return its info.
    public func stopSession() async throws -> SessionInfo {
        guard var info = activeSession else {
            throw SessionError.noActiveSession
        }

        // Stop audio capture
        await captureEngine?.stop()
        captureEngine = nil

        // Update session
        info.status = .processing
        info.endTime = Date()

        try db.run(sessions.filter(colId == info.id).update(
            colStatus <- info.status.rawValue,
            colEndTime <- info.endTime?.timeIntervalSince1970
        ))

        activeSession = nil
        return info
    }

    /// Mark a session as complete.
    public func markComplete(sessionId: String) throws {
        try db.run(sessions.filter(colId == sessionId).update(
            colStatus <- SessionStatus.complete.rawValue
        ))
    }

    /// Mark a session as failed.
    public func markFailed(sessionId: String) throws {
        try db.run(sessions.filter(colId == sessionId).update(
            colStatus <- SessionStatus.failed.rawValue
        ))
    }

    // MARK: - Queries

    /// List all sessions, most recent first.
    public func listSessions() throws -> [SessionInfo] {
        try db.prepare(sessions.order(colStartTime.desc)).map { row in
            SessionInfo(
                id: row[colId],
                status: SessionStatus(rawValue: row[colStatus]) ?? .failed,
                pipelineName: row[colPipeline],
                startTime: Date(timeIntervalSince1970: row[colStartTime]),
                endTime: row[colEndTime].map { Date(timeIntervalSince1970: $0) },
                directoryPath: row[colDirectory]
            )
        }
    }

    /// Get a specific session by ID.
    public func getSession(id: String) throws -> SessionInfo? {
        try db.pluck(sessions.filter(colId == id)).map { row in
            SessionInfo(
                id: row[colId],
                status: SessionStatus(rawValue: row[colStatus]) ?? .failed,
                pipelineName: row[colPipeline],
                startTime: Date(timeIntervalSince1970: row[colStartTime]),
                endTime: row[colEndTime].map { Date(timeIntervalSince1970: $0) },
                directoryPath: row[colDirectory]
            )
        }
    }

    /// Get the currently active session, if any.
    public var currentSession: SessionInfo? {
        activeSession
    }
}

// MARK: - Errors

public enum SessionError: Error, LocalizedError {
    case sessionAlreadyActive
    case noActiveSession
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive: "A session is already active"
        case .noActiveSession: "No active session"
        case .sessionNotFound(let id): "Session not found: \(id)"
        }
    }
}
