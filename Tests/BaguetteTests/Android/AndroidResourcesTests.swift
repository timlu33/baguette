import Testing
import Foundation
@testable import Baguette

@Suite("AndroidResources")
struct AndroidResourcesTests {

    private func find(
        env: [String: String] = [:],
        sourceTree: String? = nil,
        bundled: String? = nil,
        existing: Set<String>
    ) -> String? {
        AndroidResources.serverJar(
            environment: env, sourceTree: sourceTree, bundledJar: bundled,
            exists: { existing.contains($0) }
        )?.path
    }

    @Test func `should name the jar after the server version baguette speaks`() {
        #expect(AndroidResources.serverJarName == "scrcpy-server-v\(ScrcpyLaunch.serverVersion)")
    }

    @Test func `should prefer an explicit BAGUETTE_SCRCPY_SERVER`() {
        let found = find(
            env: ["BAGUETTE_SCRCPY_SERVER": "/mine/server.jar"],
            sourceTree: "/src", existing: ["/mine/server.jar", "/src/scrcpy-server-v3.3.3"]
        )
        #expect(found == "/mine/server.jar")
    }

    @Test func `should use the source tree before the installed bundle`() {
        let found = find(
            sourceTree: "/src", bundled: "/bundle/jar",
            existing: ["/src/scrcpy-server-v3.3.3", "/bundle/jar"]
        )
        #expect(found == "/src/scrcpy-server-v3.3.3")
    }

    @Test func `should fall back to the installed bundle`() {
        #expect(find(sourceTree: "/src", bundled: "/bundle/jar", existing: ["/bundle/jar"]) == "/bundle/jar")
    }

    @Test func `should find nothing when the jar is not shipped`() {
        #expect(find(sourceTree: "/src", bundled: "/bundle/jar", existing: []) == nil)
    }
}
