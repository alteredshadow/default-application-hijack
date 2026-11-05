import Foundation

@main
struct HandlerResolverTests {
    static func main() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandlerResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = temporaryDirectory.appendingPathComponent("fixture.pdf")
        try Data().write(to: fixture)

        let selected = try resolveApplicationPath(for: fixture.path) { _ in
            URL(fileURLWithPath: "/Applications/Preview.app")
        }
        precondition(selected == "/Applications/Preview.app")

        let missingPath = temporaryDirectory.appendingPathComponent("missing.pdf").path
        do {
            _ = try resolveApplicationPath(for: missingPath) {
                _ in URL(fileURLWithPath: "/Applications/Preview.app")
            }
            preconditionFailure("missing file unexpectedly resolved")
        } catch HandlerResolverError.fileDoesNotExist(let path) {
            precondition(path == missingPath)
        }

        do {
            _ = try resolveApplicationPath(for: fixture.path) { _ in nil }
            preconditionFailure("nil application unexpectedly resolved")
        } catch HandlerResolverError.noApplication(let path) {
            precondition(path == fixture.path)
        }

        let normalized = try resolveApplicationPath(for: temporaryDirectory.path + "/./fixture.pdf") { url in
            precondition(url.path == fixture.path)
            return URL(fileURLWithPath: "/Applications/./Preview.app")
        }
        precondition(normalized == "/Applications/Preview.app")

        print("HandlerResolverTests: PASS")
    }
}
