// 検索の速さを release で測る小さな道具。
//   swift run -c release search-bench <ファイル> <語>
import Foundation
import MrEditorCore

let args = CommandLine.arguments
// 第 2 引数が "scan" なら、照合せず舐めるだけ（mmap の下限値）。
if args.count == 3, args[2] == "scan" {
    guard let r = SearchBench.scan(path: args[1]) else {
        FileHandle.standardError.write(Data("開けない: \(args[1])\n".utf8)); exit(1)
    }
    print("\(r.encoding)\t\(r.bytes) byte\t改行 \(r.matchedLines)\t"
          + String(format: "%.2f", r.seconds) + " s")
    exit(0)
}

guard args.count >= 3 else {
    FileHandle.standardError.write(Data("使い方: search-bench <ファイル> <語>\n".utf8))
    exit(1)
}
guard let r = SearchBench.run(path: args[1], term: args[2]) else {
    FileHandle.standardError.write(Data("開けない: \(args[1])\n".utf8))
    exit(1)
}
print("\(r.encoding)\t\(r.bytes) byte\t\(args[2])\t\(r.matchedLines) 行\t"
      + String(format: "%.2f", r.seconds) + " s")
