// Renders Air's app icon to a 1024 px PNG with the shared artwork in Sources/Theme.swift.
// build.sh compiles this as main.swift together with Theme.swift.
//   make_icon <out.png> [aurora|ember|lagoon]
import AppKit

let out = CommandLine.arguments[1]
let theme = AirTheme(rawValue: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "") ?? .aurora
try! IconArt.png(theme: theme, size: 1024)!.write(to: URL(fileURLWithPath: out))
