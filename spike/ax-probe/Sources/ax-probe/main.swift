import Foundation

let usage = """
用法:
  ax-probe dump  [--depth N] [--max-nodes N]
      打印 Claude 窗口的辅助功能树（stdout），用来找回复文字所在的节点和 class。
      默认 --depth 200 --max-nodes 20000。建议重定向到文件: ax-probe dump > tree.txt

  ax-probe watch [--class 片段] [--interval 毫秒] [--idle 毫秒]
      实时打印 Claude 最后一条回复新增的文字，回复结束时输出字数、生成速度和扫描耗时。
      默认 --class font-claude --interval 250 --idle 1500
"""

func value(of flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func intValue(of flag: String, in args: [String], default fallback: Int) -> Int {
    guard let raw = value(of: flag, in: args) else { return fallback }
    guard let number = Int(raw), number > 0 else {
        report("\(flag) 需要正整数，收到 \"\(raw)\"")
        exit(2)
    }
    return number
}

let args = Array(CommandLine.arguments.dropFirst())

do {
    switch args.first {
    case "dump":
        try runDump(maxDepth: intValue(of: "--depth", in: args, default: 200),
                    maxNodes: intValue(of: "--max-nodes", in: args, default: 20000))
    case "watch":
        var options = WatchOptions()
        if let hint = value(of: "--class", in: args) { options.classHint = hint }
        options.interval = Double(intValue(of: "--interval", in: args, default: 250)) / 1000
        options.idle = Double(intValue(of: "--idle", in: args, default: 1500)) / 1000
        try runWatch(options)
    default:
        print(usage)
        exit(args.isEmpty || args.first == "help" || args.first == "--help" ? 0 : 2)
    }
} catch {
    report("错误: \(error)")
    exit(1)
}
