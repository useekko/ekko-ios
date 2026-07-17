import Foundation
import Testing

// The app tells users, on the screen where it asks them to switch on the scary-looking "Allow
// Full Access" toggle:
//
//     "The Ekko keyboard makes no network requests at all."
//
// That is true today. Nothing but this test keeps it true. Full Access grants the keyboard the
// network as well as the App Group, so the promise is ours to keep, not iOS's to enforce.
//
// If this fails, either remove the networking or change the copy. Do not delete the test.

@Suite("The keyboard promise")
struct NoNetworkTests {

    /// Everything the keyboard target compiles or links: its own sources, the shared theme, and
    /// EkkoCore. Directory lookups belong in the app.
    static let watchedDirectories = ["EkkoKeyboard", "Shared", "EkkoCore/Sources"]

    static let networkAPIs = [
        "URLSession", "URLRequest", "NSURLConnection", "CFReadStream", "CFWriteStream",
        "NWConnection", "NWBrowser", "Network.framework", "import Network", "CFSocket",
        "getaddrinfo", "URLDownload",
    ]

    @Test("nothing the keyboard links can reach the network")
    func keyboardCannotPhoneHome() throws {
        // ios/EkkoCore/Tests/EkkoCoreTests/NoNetworkTests.swift -> ios/
        // This lives in EkkoCore's suite, not the keyboard's, for one boring reason: `swift test`
        // runs natively on the Mac and can read the source tree, while an iOS test bundle runs
        // inside the simulator's sandbox and sees none of it.
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var scanned = 0
        var offenders: [String] = []

        for dir in Self.watchedDirectories {
            let root = iosRoot.appendingPathComponent(dir)
            guard
                let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil)
            else {
                Issue.record("could not read \(dir) — has it moved?")
                continue
            }
            for case let file as URL in walker where file.pathExtension == "swift" {
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scanned += 1

                // This file names the APIs it forbids, so it would otherwise report itself.
                if file.lastPathComponent == "NoNetworkTests.swift" { continue }

                for api in Self.networkAPIs where source.contains(api) {
                    // A comment saying "no network here" is not a network call.
                    let live = source
                        .split(separator: "\n")
                        .filter { $0.contains(api) }
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.hasPrefix("*") }
                    if !live.isEmpty {
                        offenders.append("\(dir)/\(file.lastPathComponent): \(api)")
                    }
                }
            }
        }

        #expect(scanned > 5, "scanned only \(scanned) files — the paths are probably wrong")
        #expect(
            offenders.isEmpty,
            """
            The keyboard promises users it makes no network requests, and something here can:
            \(offenders.joined(separator: "\n"))
            Move it to the app target, or change the copy in KeyboardSetupSteps.
            """)
    }
}
