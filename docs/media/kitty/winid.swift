// Print "<window id>\t<owner>" for the on-screen windows of an app, so
// record.py can capture one window with `screencapture -l`.
import CoreGraphics
import Foundation

let app = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "kitty"
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
  let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
  let layer = w[kCGWindowLayer as String] as? Int ?? 0
  if owner == app && layer == 0 {
    print("\(w[kCGWindowNumber as String]!)\t\(owner)")
  }
}
