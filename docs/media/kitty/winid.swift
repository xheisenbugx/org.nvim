// Print "<window id>\t<owner>" for the on-screen windows of an app, so
// record.py can capture one window with `screencapture -l`. With a second
// argument, only the windows of that process id (not the user's own kitty).
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let app = args.count > 1 ? args[1].lowercased() : "kitty"
let pid = args.count > 2 ? Int(args[2]) : nil
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
  let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
  let layer = w[kCGWindowLayer as String] as? Int ?? 0
  let ownerPid = w[kCGWindowOwnerPID as String] as? Int ?? -1
  if owner == app && layer == 0 && (pid == nil || pid == ownerPid) {
    print("\(w[kCGWindowNumber as String]!)\t\(owner)")
  }
}
