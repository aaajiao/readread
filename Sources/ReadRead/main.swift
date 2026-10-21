import Foundation

// Entry point. `--self-test` runs headless (no UI, no single-instance check);
// otherwise hand over to an already-running instance or start the menu bar app.
if CommandLine.arguments.dropFirst().contains("--self-test") {
    Task { @MainActor in
        exit(await SelfTest.run())
    }
    // The main run loop, not dispatchMain(): the self test's offscreen web view (the page
    // reader check) needs it, and under dispatchMain() the process crashes as soon as the web
    // view starts. The main queue, where the MainActor runs, is drained by this run loop too.
    RunLoop.main.run()
} else {
    if SingleInstance.handOffToRunningInstance() {
        exit(0)
    }
    ReadReadApp.main()
}
