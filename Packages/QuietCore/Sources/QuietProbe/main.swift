import Darwin
import Foundation
import QuietCore

let args = CommandLine.arguments
guard args.count >= 3 else { exit(2) }
let database = try ControlDatabase(directory: URL(fileURLWithPath: args[2]))
switch args[1] {
case "increment":
  for _ in 0..<Int(args[3])! { try database.update { $0.monitorFailed.toggle() } }
case "crash-before-commit":
  try database.update { state in
    state.setupComplete = true
    _exit(71)
  }
case "crash-after-commit":
  try database.update({ $0.monitorFailed = true }, project: { _ in _exit(72) })
default: exit(2)
}
