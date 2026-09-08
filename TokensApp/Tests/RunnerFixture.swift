import Foundation
import Darwin

// Synthetic helper-process fixture for RunnerChecks. No network, no HOME,
// no product flags. Modes:
//   big <bytes>                 write <bytes> to stdout AND stderr
//   sleep <secs> [--ignore-term] [--pidfile <path>]
//   exit <code> [message...]    stderr message, exit code
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: fixture big|sleep|exit ...\n".utf8))
    exit(2)
}

switch args[1] {
case "big":
    let count = args.count >= 3 ? Int(args[2]) ?? 0 : 0
    let chunk = Data(repeating: 120, count: 65536)
    var remainingOut = count
    var remainingErr = count
    let errChunk = Data(repeating: 101, count: 65536)
    while remainingOut > 0 || remainingErr > 0 {
        if remainingOut > 0 {
            let n = min(remainingOut, chunk.count)
            FileHandle.standardOutput.write(chunk.prefix(n))
            remainingOut -= n
        }
        if remainingErr > 0 {
            let n = min(remainingErr, errChunk.count)
            FileHandle.standardError.write(errChunk.prefix(n))
            remainingErr -= n
        }
    }
    exit(0)
case "sleep":
    let secs = args.count >= 3 ? Double(args[2]) ?? 0 : 0
    if args.contains("--ignore-term") {
        signal(SIGTERM, SIG_IGN)
    }
    if let idx = args.firstIndex(of: "--pidfile"), idx + 1 < args.count {
        try? String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: args[idx + 1], atomically: true, encoding: .utf8)
    }
    Thread.sleep(forTimeInterval: secs)
    exit(0)
case "exit":
    let code = args.count >= 3 ? Int32(args[2]) ?? 1 : 1
    if args.count > 3 {
        FileHandle.standardError.write(Data((args[3...].joined(separator: " ") + "\n").utf8))
    }
    exit(code)
default:
    FileHandle.standardError.write(Data("unknown fixture mode\n".utf8))
    exit(2)
}
