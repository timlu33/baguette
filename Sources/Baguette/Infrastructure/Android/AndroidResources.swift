import Foundation

/// Where the bundled scrcpy server jar lives. The same three-step
/// lookup `WebRoot` uses for the web assets: an explicit override, the
/// source tree (`swift run` from a checkout), then the SwiftPM bundle
/// that ships beside an installed binary.
enum AndroidResources {
    /// The official, unmodified scrcpy server (Apache-2.0, Genymobile).
    static let serverJarName = "scrcpy-server-v\(ScrcpyLaunch.serverVersion)"

    static var serverJar: URL? {
        serverJar(
            environment: ProcessInfo.processInfo.environment,
            sourceTree: sourceTreeDirectory(),
            bundledJar: bundledJarPath(),
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    static func serverJar(
        environment: [String: String],
        sourceTree: String?,
        bundledJar: String?,
        exists: (String) -> Bool
    ) -> URL? {
        var candidates: [String] = []
        if let override = environment["BAGUETTE_SCRCPY_SERVER"], !override.isEmpty { candidates.append(override) }
        if let sourceTree { candidates.append("\(sourceTree)/\(serverJarName)") }
        if let bundledJar { candidates.append(bundledJar) }
        return candidates.first(where: exists).map { URL(fileURLWithPath: $0) }
    }

    private static func sourceTreeDirectory() -> String? {
        // …/Sources/Baguette/Infrastructure/Android/AndroidResources.swift
        let file = URL(fileURLWithPath: #filePath)
        let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("Resources/Android").path
    }

    private static func bundledJarPath() -> String? {
        // Resolved by path rather than `Bundle.module`, whose accessor
        // traps when the bundle is missing — see `WebRoot`. `.copy` keeps
        // the folder name, so the jar sits under `Android/` in the bundle.
        #if canImport(Darwin)
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let cstr = info.dli_fname else { return nil }
        let exeDir = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        let bundleURL = exeDir.appendingPathComponent("Baguette_Baguette.bundle")
        guard FileManager.default.fileExists(atPath: bundleURL.path),
              let bundle = Bundle(url: bundleURL) else { return nil }
        return bundle.url(forResource: serverJarName, withExtension: nil, subdirectory: "Android")?.path
        #else
        return nil // baguette is macOS-only; this arm exists so the pure parts build on Linux CI.
        #endif
    }
}
