import Foundation
import Testing
@testable import StandupCore

@Test func ringBufferWriteAndRead() async throws {
    let buffer = RingBuffer(minimumCapacity: 1024)

    // Write some samples
    let samples: [Float] = [1.0, 2.0, 3.0, 4.0]
    samples.withUnsafeBufferPointer { ptr in
        buffer.write(from: ptr.baseAddress!, count: 4)
    }

    #expect(buffer.availableToRead == 4)

    // Read them back
    var output = [Float](repeating: 0, count: 4)
    output.withUnsafeMutableBufferPointer { ptr in
        buffer.read(into: ptr.baseAddress!, count: 4)
    }

    #expect(output == [1.0, 2.0, 3.0, 4.0])
    #expect(buffer.availableToRead == 0)
}

@Test func ringBufferOverflow() async throws {
    let buffer = RingBuffer(minimumCapacity: 4) // rounds to 4

    let samples: [Float] = [1, 2, 3, 4, 5, 6]
    let written = samples.withUnsafeBufferPointer { ptr in
        buffer.write(from: ptr.baseAddress!, count: 6)
    }

    // Should only write up to capacity
    #expect(written == 4)
}

@Test func pluginConfigParsing() async throws {
    let config = PluginConfig(values: [
        "threshold_db": "-40",
        "name": "test",
        "count": "5",
    ])

    #expect(config.double(for: "threshold_db") == -40.0)
    #expect(config.string(for: "name") == "test")
    #expect(config.int(for: "count") == 5)
    #expect(config.string(for: "missing", default: "fallback") == "fallback")
}

@Test func livePluginChainProcessing() async throws {
    let chain = LivePluginChain(channel: .mic)

    // With no plugins, buffer should be unchanged
    var samples: [Float] = [0.5, -0.5, 0.3, -0.3]
    samples.withUnsafeMutableBufferPointer { ptr in
        chain.process(buffer: ptr.baseAddress!, frameCount: 4)
    }

    #expect(samples == [0.5, -0.5, 0.3, -0.3])
}

@Test func sessionInfoCodable() async throws {
    let info = SessionInfo(
        id: "test-123",
        status: .active,
        pipelineName: "standup-comics",
        startTime: Date(),
        directoryPath: "/tmp/test"
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(info)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(SessionInfo.self, from: data)

    #expect(decoded.id == "test-123")
    #expect(decoded.status == .active)
    #expect(decoded.pipelineName == "standup-comics")
}

