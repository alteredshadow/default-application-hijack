import Foundation

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@main
struct EventLogTests {
    static func main() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let logURL = temporaryDirectory.appendingPathComponent("events.jsonl")
        let logger = EventLogger(logURL: logURL)
        let paths = ["/tmp/report with spaces.pdf", "/tmp/quote\"-café.pdf"]
        let timestamp = Date(timeIntervalSince1970: 1_797_000_000)

        let written = try logger.append(
            paths: paths,
            eventType: "open-files",
            timestamp: timestamp,
            processID: 4242
        )
        let line = try String(contentsOf: logURL, encoding: .utf8)
        let decoded = try JSONDecoder.iso8601.decode(
            OpenEvent.self,
            from: Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        )
        precondition(decoded == written)
        precondition(decoded.paths == paths)
        precondition(decoded.timestamp == timestamp)
        precondition(decoded.processID == 4242)
        precondition(decoded.eventType == "open-files")
        precondition(line.hasSuffix("\n"))

        _ = try logger.append(paths: ["/tmp/second.pdf"], processID: 4243)
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        precondition(lines.count == 2)
        precondition(String(lines[0]) + "\n" == line)
        let second = try JSONDecoder.iso8601.decode(OpenEvent.self, from: Data(lines[1].utf8))
        precondition(second.paths == ["/tmp/second.pdf"])
        precondition(second.processID == 4243)
        precondition(second.eventType == "open-files")
        precondition(contents.hasSuffix("\n"))

        print("EventLogTests: PASS")
    }
}
