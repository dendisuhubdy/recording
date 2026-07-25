import Foundation

/// A unique directory that deletes itself when the test's reference is released.
///
/// Tests run in parallel, so every test needs its own path — sharing one would
/// make failures depend on execution order.
final class TempDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = URL.temporaryDirectory.appending(path: "MeetingCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
