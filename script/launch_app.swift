import AppKit
import Foundation
import Darwin

// Development launcher: stop only this bundle identity, wait for a normal
// termination, launch without activation, and verify the actual bundle path.
let arguments = CommandLine.arguments
let bundleID = "com.klovinad.MacResourceBar"
guard arguments.count >= 2 else {
    fputs("usage: launch_app.swift <app-bundle> [--stop-only]\n", stderr)
    exit(2)
}
let targetURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
guard let bundle = Bundle(url: targetURL), bundle.bundleIdentifier == bundleID,
      let executable = bundle.executableURL,
      FileManager.default.isExecutableFile(atPath: executable.path) else {
    fputs("Refusing to launch an invalid MacResourceBar bundle.\n", stderr)
    exit(2)
}

Task { @MainActor in
    let previous = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    for app in previous { app.terminate() }
    for _ in 0..<50 {
        if previous.allSatisfy({ $0.isTerminated }) { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    guard previous.allSatisfy({ $0.isTerminated }) else {
        fputs("MacResourceBar did not quit normally. The running app was preserved; close it and retry.\n", stderr)
        exit(1)
    }
    if arguments.contains("--stop-only") { exit(0) }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = true
    if arguments.contains("--show-popover") {
        configuration.arguments = ["--show-popover"]
    }
    do {
        let app = try await NSWorkspace.shared.openApplication(at: targetURL, configuration: configuration)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        guard !app.isTerminated,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == targetURL,
              app.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == executable.standardizedFileURL.resolvingSymlinksInPath() else {
            fputs("Launched process does not correspond to the requested bundle.\n", stderr)
            exit(1)
        }
        print("Verified MacResourceBar PID \(app.processIdentifier): \(targetURL.path)")
        exit(0)
    } catch {
        fputs("Could not launch MacResourceBar: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
