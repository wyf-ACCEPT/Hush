// Makes /Applications/Hush.app the default app for common video file extensions.
// webm is left to Chrome on purpose.
// Usage: swift tools/set_default.swift [path/to/Hush.app]
import AppKit
import UniformTypeIdentifiers

let app = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/Applications/Hush.app")
let extensions = ["mp4", "m4v", "mov", "mkv", "avi", "flv", "f4v", "rmvb", "rm", "wmv",
                  "ts", "m2ts", "mts", "mpg", "mpeg", "3gp", "ogv", "vob"]

// Resolve each extension to the content type this Mac actually uses (other players may
// have registered their own UTI for e.g. mkv), and set the default per unique type.
var types: [UTType: [String]] = [:]
for ext in extensions {
    guard let type = UTType(filenameExtension: ext) else { continue }
    types[type, default: []].append(ext)
}

let group = DispatchGroup()
var failures: [String] = []
for (type, exts) in types {
    group.enter()
    NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
        if let error { failures.append("\(exts.joined(separator: ",")) (\(type.identifier)): \(error.localizedDescription)") }
        group.leave()
    }
}
group.notify(queue: .main) {
    for ext in extensions {
        guard let type = UTType(filenameExtension: ext) else { print("\(ext): no type"); continue }
        let handler = NSWorkspace.shared.urlForApplication(toOpen: type)?.path ?? "none"
        print("\(ext.padding(toLength: 5, withPad: " ", startingAt: 0)) \(type.identifier) -> \(handler)")
    }
    failures.forEach { print("FAILED \($0)") }
    exit(failures.isEmpty ? 0 : 1)
}
dispatchMain()
