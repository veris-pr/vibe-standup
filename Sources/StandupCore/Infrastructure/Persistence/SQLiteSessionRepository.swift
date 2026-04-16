/// Infrastructure: SQLite-backed session repository.

import Foundation
import SQLite

public final class SQLiteSessionRepository: SessionRepository, @unchecked Sendable {
    private let db: Connection

    private let sessions = Table("sessions")
    private let colId = SQLite.Expression<String>("id")
    private let colStatus = SQLite.Expression<String>("status")
    private let colPipeline = SQLite.Expression<String>("pipeline")
    private let colCaptureSource = SQLite.Expression<String>("capture_source")
    private let colStartTime = SQLite.Expression<Double>("start_time")
    private let colEndTime = SQLite.Expression<Double?>("end_time")
    private let colDirectory = SQLite.Expression<String>("directory")

    public init(dbPath: String) throws {
        self.db = try Connection(dbPath)
        try db.run(sessions.create(ifNotExists: true) { t in
            t.column(colId, primaryKey: true)
            t.column(colStatus)
            t.column(colPipeline)
            t.column(colCaptureSource, defaultValue: AudioCaptureSource.screenCapture.rawValue)
            t.column(colStartTime)
            t.column(colEndTime)
            t.column(colDirectory)
        })

        // Migrate existing DBs: add capture_source column if missing
        let tableInfo = try db.prepare("PRAGMA table_info(sessions)")
        let columns = tableInfo.map { $0[1] as? String ?? "" }
        if !columns.contains("capture_source") {
            try db.run("ALTER TABLE sessions ADD COLUMN capture_source TEXT DEFAULT '\(AudioCaptureSource.screenCapture.rawValue)'")
        }
    }

    public func save(_ session: Session) throws {
        try db.run(sessions.insert(
            colId <- session.id,
            colStatus <- session.status.rawValue,
            colPipeline <- session.pipelineName,
            colCaptureSource <- session.captureSource.rawValue,
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
            captureSource: AudioCaptureSource(rawValue: row[colCaptureSource]) ?? .screenCapture,
            startTime: Date(timeIntervalSince1970: row[colStartTime]),
            endTime: row[colEndTime].map { Date(timeIntervalSince1970: $0) },
            directoryPath: row[colDirectory]
        )
    }
}
