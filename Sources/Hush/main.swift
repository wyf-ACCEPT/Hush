import AppKit

// libmpv requires the C numeric locale for parsing floats.
setlocale(LC_NUMERIC, "C")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
