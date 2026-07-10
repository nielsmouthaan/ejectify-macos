import Cocoa

Log.setupDiagnosticsLogger()
Log.app.log("Application launched")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
