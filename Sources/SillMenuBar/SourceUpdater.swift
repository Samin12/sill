import Foundation
import Observation

/// The personal fork's source updater. Official builds without SourceUpdates.plist keep their
/// release-page updater. Checking is read-only; only Update & Restart runs the bundled helper.
@MainActor @Observable
final class SourceUpdater {
    private(set) var busy = false
    private(set) var line = "Check for changes in the original Sill."
    private(set) var failed = false
    private(set) var latestRevision: String?
    private(set) var resultID = 0

    let checkout: String?
    let fork: String?
    let upstream: String?
    let installedRevision: String?
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Sill/SourceUpdate.log")
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var lastCheck: Date?

    init(bundle: Bundle = .main) {
        checkout = bundle.object(forInfoDictionaryKey: "SillSourceCheckout") as? String
        fork = bundle.object(forInfoDictionaryKey: "SillForkRepository") as? String
        upstream = bundle.object(forInfoDictionaryKey: "SillUpstreamRepository") as? String
        installedRevision = bundle.object(forInfoDictionaryKey: "SillUpstreamRevision") as? String
    }

    var available: Bool {
        !CommandLine.arguments.contains("--synthetic") && checkout != nil && fork != nil && upstream != nil && installedRevision != nil
    }
    var updateAvailable: Bool { latestRevision.map { $0 != installedRevision } ?? false }

    func start(automatic: Bool) {
        guard available else { return }
        setAutomatic(automatic)
        if automatic { checkNow() }
    }

    func setAutomatic(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard available, enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    func checkIfDue() {
        if lastCheck.map({ Date().timeIntervalSince($0) < 24 * 3600 }) != true { checkNow() }
    }

    func checkNow() {
        guard available, !busy, let upstream else { return }
        busy = true
        failed = false
        line = "Checking the original Sill…"
        Task { @MainActor in
            defer { busy = false; resultID += 1 }
            do {
                let url = URL(string: "https://api.github.com/repos/\(upstream)/commits/main")!
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                request.setValue("Sill-Source-Updater", forHTTPHeaderField: "User-Agent")
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.timeoutIntervalForResource = 20
                let session = URLSession(configuration: config, delegate: SourceUpdateRedirects(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw CheckError("GitHub did not return a response.") }
                guard response.statusCode == 200 else { throw CheckError("GitHub returned HTTP \(response.statusCode). Try again later.") }
                guard data.count < 1 << 20,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sha = object["sha"] as? String, sha.count == 40, sha.allSatisfy(\.isHexDigit)
                else { throw CheckError("GitHub returned an invalid commit.") }
                latestRevision = sha
                lastCheck = Date()
                line = updateAvailable ? "An update from the original Sill is available."
                    : "Up to date with the original Sill (\(sha.prefix(7)))."
            } catch {
                failed = true
                line = "Couldn’t check for updates: \(error.localizedDescription)"
            }
        }
    }

    func updateAndRestart() {
        guard available, !busy, let checkout, let fork, let upstream,
              let helper = Bundle.main.url(forResource: "update-from-upstream", withExtension: "sh") else { return }
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: logURL, options: .atomic)
            let output = try FileHandle(forWritingTo: logURL)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/bash")
            child.arguments = [helper.path, checkout, fork, upstream, Bundle.main.bundlePath]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            child.standardError = output
            child.terminationHandler = { [weak self] child in
                try? output.close()
                Task { @MainActor in
                    guard let self else { return }
                    self.busy = false
                    self.process = nil
                    self.failed = child.terminationStatus != 0
                    self.line = self.failed
                        ? "The update stopped. Your installed app was kept. Open Update Log for details."
                        : "Update complete. Sill is restarting."
                    self.resultID += 1
                }
            }
            try child.run()
            try? output.close() // the child's file descriptors stay open through the app's restart
            process = child
            busy = true
            failed = false
            line = "Updating Sill… It will restart when ready."
        } catch {
            failed = true
            line = "Couldn’t start the update: \(error.localizedDescription)"
            resultID += 1
        }
    }

    private struct CheckError: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}

private final class SourceUpdateRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "api.github.com" ? request : nil)
    }
}
