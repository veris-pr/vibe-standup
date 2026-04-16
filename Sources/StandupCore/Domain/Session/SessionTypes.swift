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
public struct Session: Sendable, Codable, Equatable {
    public let id: String
    public private(set) var status: SessionStatus
    public let pipelineName: String
    public let captureSource: AudioCaptureSource
    public let startTime: Date
    public private(set) var endTime: Date?
    public let directoryPath: String

    public init(id: String, status: SessionStatus = .active, pipelineName: String, captureSource: AudioCaptureSource = .screenCapture, startTime: Date = Date(), endTime: Date? = nil, directoryPath: String) {
        self.id = id
        self.status = status
        self.pipelineName = pipelineName
        self.captureSource = captureSource
        self.startTime = startTime
        self.endTime = endTime
        self.directoryPath = directoryPath
    }

    /// Transition to processing state (session stopped, pipeline running).
    public mutating func markProcessing() throws {
        guard status == .active else {
            throw SessionError.invalidTransition(from: status, to: .processing)
        }
        status = .processing
        endTime = Date()
    }

    /// Transition to complete state (pipeline finished successfully).
    public mutating func markComplete() throws {
        guard status == .processing else {
            throw SessionError.invalidTransition(from: status, to: .complete)
        }
        status = .complete
    }

    /// Transition to failed state (pipeline encountered an error).
    public mutating func markFailed() throws {
        guard status == .active || status == .processing else {
            throw SessionError.invalidTransition(from: status, to: .failed)
        }
        status = .failed
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
