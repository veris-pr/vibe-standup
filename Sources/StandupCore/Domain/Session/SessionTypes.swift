/// Domain types for the Session bounded context.
///
/// Session is the aggregate root — it owns the lifecycle of an audio
/// capture and its associated pipeline run. All data is scoped to a session.

import Foundation

// MARK: - Session Entity (Aggregate Root)

/// The states a session transitions through.
public enum SessionStatus: String, Sendable, Codable {
    case active
    case processing
    case complete
    case failed
}

/// A capture session — the aggregate root of the Session domain.
/// Immutable snapshot; mutations happen through the repository.
public struct Session: Sendable, Codable, Equatable {
    public let id: String
    public var status: SessionStatus
    public let pipelineName: String
    public let startTime: Date
    public var endTime: Date?
    public let directoryPath: String

    public init(id: String, status: SessionStatus = .active, pipelineName: String, startTime: Date = Date(), endTime: Date? = nil, directoryPath: String) {
        self.id = id
        self.status = status
        self.pipelineName = pipelineName
        self.startTime = startTime
        self.endTime = endTime
        self.directoryPath = directoryPath
    }

    /// Path to the audio chunks directory within this session.
    public var chunksPath: String {
        (directoryPath as NSString).appendingPathComponent("chunks")
    }

    /// Path to a stage's output directory within this session.
    public func stageOutputPath(for stageId: String) -> String {
        (directoryPath as NSString).appendingPathComponent(stageId)
    }
}

// MARK: - Session Repository Port (contract)

/// Port defining how sessions are persisted and queried.
/// Infrastructure provides the adapter (e.g., SQLite).
public protocol SessionRepository: Sendable {
    func save(_ session: Session) throws
    func update(_ session: Session) throws
    func find(id: String) throws -> Session?
    func listAll() throws -> [Session]
}

// MARK: - Session Errors

public enum SessionError: Error, LocalizedError, Sendable {
    case alreadyActive
    case noActiveSession
    case notFound(String)
    case invalidTransition(from: SessionStatus, to: SessionStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyActive: "A session is already active"
        case .noActiveSession: "No active session"
        case .notFound(let id): "Session not found: \(id)"
        case .invalidTransition(let from, let to): "Invalid session transition: \(from.rawValue) → \(to.rawValue)"
        }
    }
}
