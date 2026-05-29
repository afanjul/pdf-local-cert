import Foundation

/// Talks to the bundled `pdfsigner-core` sidecar over the line-delimited JSON
/// protocol. One request line in, one response line out, per invocation.
struct CoreClient {
    let workDir: URL

    /// Locate the sidecar: app bundle Helpers/ first, then the dev build dir.
    static func corePath() -> String {
        if let helper = Bundle.main.url(forResource: "pdfsigner-core", withExtension: nil, subdirectory: "Helpers") {
            return helper.path
        }
        let bundleHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/pdfsigner-core")
        if FileManager.default.isExecutableFile(atPath: bundleHelper.path) {
            return bundleHelper.path
        }
        // Dev fallback.
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("core/target/release/pdfsigner-core")
        return dev.path
    }

    func request(_ json: [String: Any]) throws -> [String: Any] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.corePath())
        var env = ProcessInfo.processInfo.environment
        env["PDFSIGNER_WORK"] = workDir.path
        proc.environment = env

        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout

        try proc.run()

        let line = try JSONSerialization.data(withJSONObject: json)
        stdin.fileHandleForWriting.write(line)
        stdin.fileHandleForWriting.write("\n".data(using: .utf8)!)
        try? stdin.fileHandleForWriting.close()

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let firstLine = String(data: out, encoding: .utf8)?
            .split(separator: "\n").first,
              let respData = String(firstLine).data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw SigningError.signFailed("respuesta inválida del núcleo")
        }
        return obj
    }
}
