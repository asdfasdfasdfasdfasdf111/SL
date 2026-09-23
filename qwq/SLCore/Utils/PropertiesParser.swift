//
//  PropertiesParser.swift
//  SL启动器
//
//  极简的 Java .properties 解析器（读本地化词条等资源文件）：
//  按行扫描、跳过整行注释、把 `key=value` 收进字典。
//
//  ⚠️ 它**不是** java.util.Properties 的完整实现，只覆盖「简单键值对」这一小片。
//  具体差异见 parse / parsePropertyLine 的注释 —— 将来要读带转义、续行或 `:` 分隔符的
//  properties 时切勿直接复用本类型。
//
//  Created by YiZhiMCQiu on 2025/5/18.
//

import Foundation

public struct PropertiesParser {
    /// 把 properties 文件解析成字典。**永不抛错、永不返回 nil**。
    ///
    /// - 读不到文件（不存在 / 无权限 / 非 UTF-8）时打一条日志并返回**空字典**——
    ///   调用方无法区分「文件不存在」与「文件存在但没有任何键值对」，属静默降级。
    /// - 同一个 key 出现多次时**后来者覆盖先来者**（逐行 `result[key] = value`）。
    public static func parse(fileURL: URL) -> [String: String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            err("文件读取失败")
            return [:]
        }
        
        var result = [String: String]()
        let lines = content.components(separatedBy: .newlines)
        
        // 空行、以及行首为 # 或 ! 的行整体跳过。
        // 这里只判断**行首**字符，不做转义处理：`\#` 不会被当成字面量 #。
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty,
                  !trimmedLine.starts(with: "#"),
                  !trimmedLine.starts(with: "!") else {
                continue
            }
            if let (key, value) = parsePropertyLine(trimmedLine) {
                result[key] = value
            }
        }
        
        return result
    }
    
    /// 拆一行 `key=value`；拿不到恰好两段就返回 nil（整行被丢弃）。
    ///
    /// 与 java.util.Properties 的三处差异（读第三方 properties 时必须留意）：
    /// 1. 只认 `=` 作分隔符，**不认 `:`**（标准实现两者都认）；
    /// 2. 不支持 `\` 续行，也不解析 `\uXXXX` / `\n` 等转义序列，一律按字面量处理；
    /// 3. 值内部的 `#` / `!` 会被当作注释起始而截断（标准实现只在行首认注释），
    ///    例如值为 `abc#123` 时只会读到 `abc`。
    private static func parsePropertyLine(_ line: String) -> (key: String, value: String)? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        // maxSplits: 1 —— 只切第一个 =，值里允许再出现 =；
        // omittingEmptySubsequences: false —— `key=` 仍会切成两段（值为空串）而不是一段。
        // 于是「完全没有 = 的行」只有一段，被下面这行丢掉。
        guard parts.count == 2 else { return nil }
        
        let rawKey = String(parts[0]).trimmingCharacters(in: .whitespaces)
        var rawValue = String(parts[1])
        
        // 截到第一个 # 或 ! 之前，视作行内注释。
        // ⚠️ 值里合法出现的 # / ! 也会被切掉（见上方差异 3）。
        if let commentIndex = rawValue.firstIndex(where: { $0 == "#" || $0 == "!" }) {
            rawValue = String(rawValue[..<commentIndex])
        }
        
        // 去首尾空白后，再剥掉首尾的引号（只剥一层、只剥行首行尾）：
        // `"abc"` → `abc`；`"ab"c"` → `ab"c`（内部引号原样保留）。
        let trimmedValue = rawValue
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        
        return (rawKey, trimmedValue)
    }
}
