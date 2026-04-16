/// Infrastructure: SQLite-backed session repository.

import Foundation
import SQLite

public final class SQLiteSessionRepository: SessionRepository, @unchecked Sendable {
    private let db: Connection

    private let sessions = Table("sessions")
    private let colId = SQLite.Expression<String>("id")
    private let colStatus = SQLite.Expression<String>("status")
    private let colPipeline = SQLite.Expression<String>("pipeline")
    private let colStartTime = SQLite.Expression<Double>("start_time")
    private let colEndTime = SQLite.Expression<Double?>("end_time")
    private let colDirectory = SQLite.Expression<String>("directory")

    public init(dbPath: String) throws {
        self.db = try Connection(dbPath)
        try db.run(sessions.create(ifNotExists: true) { t in
            t.column(colId, primaryKey: true)
            t.column(colStatus)
            t.column(colPipeline)
            t.column(colStartTime)
            t.column(colEndTime)
            t.column(colDirectory)
        })
    }

    public func save(_ session: Session) throws {
        try db.run(sessions.insert(
            colId <- session.id,
            colStatus <- session.status.rawValue,
            colPipeline <- session.pipelineName,
            colStartTime <- session.startTime.timeIntervalSince1970,
            colEndTime <- session.endTime?.timeIntervalSince1970,
            colDirectory <- session.directoryPath
        ))
    }

    public func update(_ session: Session) throws {
        try db.run(sessions.filter(colId == session.id).update(
            colStatus <- session.status.rawValue,
            colEndTime <- session.endTime?.timeIntervalSince1970
        ))
    }

    public func find(id: String) throws -> Session? {
        try db.pluck(sessions.filter(colId == id)).map(rowToSession)
    }

    public func listAll() throws -> [Session] {
        try db.prepare(sessions.order(colStartTime.desc)).map(rowToSession)
    }

    private func rowToSession(_ row: Row) -> Session {
        Session(
            id: row[colId],
            status: SessionStatus(rawValue: row[colStatus]) ?? .failed,
            pipelineName: row[colPipeline],
            startTime: Date(timeIntervalSince1970: row[colStartTime]),
            endTime: row[colEndTime].map { Date(timeIntervalSince1970: $0) },
            directoryPath: row[colDirectory]
        )
    }
}
