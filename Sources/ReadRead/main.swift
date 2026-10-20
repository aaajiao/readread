import Foundation

// Entry point. `--self-test` runs headless (no UI, no single-instance check);
// otherwise hand over to an already-running instance or start the menu bar app.
if CommandLine.arguments.dropFirst().contains("--self-test") {
    Task { @MainActor in
        exit(await SelfTest.run())
    }
    dispatchMain()
} else {
    if SingleInstance.handOffToRunningInstance() {
        exit(0)
    }
    ReadReadApp.main()
}
