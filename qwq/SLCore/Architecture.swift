//
//  Architecture.swift
//  SL启动器
//
//  CPU 架构的识别与兼容性判定。这里回答两个不同的问题：
//  1. 当前**进程**是什么架构（`system`）—— 决定能否直接执行某个二进制；
//  2. 某个**可执行文件**是什么架构（`getArchOfFile`）—— 读 Mach-O 文件头，不启动它。
//
//  典型用途是挑 JVM：目标 java 与系统架构一致 → 原生直跑（`.direct`）；
//  系统 arm64 而文件是 x64 → 走 Rosetta（`.transition`）；其余判为不可用。
//  该策略见 SLCore/Minecraft/MinecraftInstanceJava.swift 的 findSuitableJava。
//
//  Created by YiZhiMCQiu on 8/11/25.
//

import Foundation

/// 架构标识。用 `enum` 而非 String 枚举：取值集合是封闭的，
/// 且需要一个「同时包含多种架构」的额外状态 `.fatFile`。
public enum Architecture {
    /// 当前进程看到的架构。首次访问时调用 `uname` 取机器标识并缓存。
    ///
    /// ⚠️ 它反映的是**进程视角**而不是硬件真相：本 App 若被 Rosetta 转译运行，
    /// 这里会拿到 `x86_64` 并返回 `.x64`。这对启动器恰好是正确的语义 ——
    /// 它真正要判断的是「本进程能不能直接 exec 目标二进制」。
    /// ⚠️ 除 `arm64` 之外的一切标识都被归为 `.x64`（见实现），
    /// 将来若出现第三种架构会被静默误判为 x64。
    public static var system: Architecture {
        get {
            // 惰性缓存：uname + Mirror 反射的开销不小，而本属性会被高频读取。
            // ⚠️ 这个缓存的读写没有加锁，是「非 Sendable 的可变全局状态」——
            // 并发首访理论上构成数据竞争（实际后果只是重复计算，不会得到错误值）。
            if _systemArch == nil {
                var systemInfo = utsname()
                uname(&systemInfo)
                let machineMirror = Mirror(reflecting: systemInfo.machine)
                // utsname.machine 是定长的 C 字符数组（末尾补 \0），
                // 所以靠 Mirror 逐字节取出、遇到 0 即停，再拼成字符串。
                let identifier = machineMirror.children.reduce("") { identifier, element in
                    guard let value = element.value as? Int8, value != 0 else { return identifier }
                    return identifier + String(UnicodeScalar(UInt8(value)))
                }
                _systemArch = (identifier == "arm64" ? .arm64 : .x64)
            }
            return _systemArch!
        }
    }
    
    /// 读可执行文件的 Mach-O 文件头判断架构；**不执行该文件**，只读开头若干字节。
    ///
    /// 任何一步读失败（不存在 / 无权限 / 太短 / 不是 Mach-O）都返回 `.unknown`，
    /// 既不抛错也不打日志 —— 调用方须把 `.unknown` 当作「不可用」处理。
    public static func getArchOfFile(_ executableURL: URL) -> Architecture {
        guard let fh = try? FileHandle(forReadingFrom: executableURL) else { return .unknown }
        defer { try? fh.close() }
        
        // 魔数按**主机字节序**读（x86_64 / arm64 都是小端），所以同一个磁盘上的大端魔数
        // 会呈现为字节序颠倒的值 —— 下一行的四个值正是把
        // FAT_MAGIC / FAT_CIGAM / FAT_MAGIC_64 / FAT_CIGAM_64 的两种字节序全数覆盖。
        // ⚠️ 其中 0xCAFEBABE 同时也是 Java `.class` 的魔数：把 .class 喂进来会被误判成
        // fat 二进制（本方法实际只用于 java 可执行文件与 jar 内文件，暂不构成问题）。
        guard let magicData = try? fh.read(upToCount: 4), magicData.count == 4 else { return .unknown }
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let isFat = (magic == 0xBEBAFECA || magic == 0xBFBAFECA || magic == 0xCAFEBABE || magic == 0xCAFEBABF)
        
        if isFat {
            guard let nfatArchData = try? fh.read(upToCount: 4), nfatArchData.count == 4 else { return .unknown }
            // fat 头部的字段**在磁盘上固定是大端序**（与主机字节序无关），
            // 因此这里必须显式 `.bigEndian`；漏掉它会在 Intel 机器上把 CPU 数量读错。
            let nfatArch = nfatArchData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            var foundX64 = false
            var foundArm64 = false
            
            for _ in 0..<nfatArch {
                // 每个 fat_arch 条目固定 20 字节：cputype / cpusubtype / offset / size / align，
                // 各占 4 字节。这里只关心开头的 cputype，余下 16 字节随文件指针读掉即可。
                guard let archData = try? fh.read(upToCount: 20), archData.count == 20 else { return .unknown }
                let cputype = archData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                switch cputype {
                case 0x1000007: foundX64 = true // CPU_TYPE_X86_64
                case 0x100000C: foundArm64 = true // CPU_TYPE_ARM64
                default: break
                }
            }
            // 两种架构都出现 → 通用二进制；只出现一种则按那一种归类。
            // 注意这里把 fat 文件**按其实际包含的架构**归类，而不是一律返回 `.fatFile`：
            // 只含 x64 的「伪 fat」也因此得到 `.x64`，正是调用方需要的判断粒度。
            if foundX64 && foundArm64 {
                return .fatFile
            } else if foundArm64 {
                return .arm64
            } else if foundX64 {
                return .x64
            } else {
                return .unknown
            }
        }
        
        guard let cputypeData = try? fh.read(upToCount: 4), cputypeData.count == 4 else { return .unknown }
        // 非 fat 的普通 Mach-O：cputype 紧跟在 4 字节魔数之后（偏移 4）。
        // 这里**不**加 `.bigEndian` —— x86_64 / arm64 的 Mach-O 头部本身就是小端，
        // 用主机字节序读正好；若将来遇到大端 Mach-O（PowerPC 时代）会误判。
        let cputype = cputypeData.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch cputype {
        case 0x100000C: return .arm64
        case 0x1000007: return .x64
        default: return .unknown
        }
    }
    
    /// `system` 的缓存。声明位置排在方法之后纯属排版习惯，与可见性无关。
    private static var _systemArch: Architecture? = nil
    /// ARM64，Apple Silicon
    case arm64
    
    /// x86_64，Intel Chip
    case x64
    
    /// Universal Binary，至少包含 ARM64 与 x86_64
    case fatFile
    
    /// 未知
    case unknown
    
    /// 是否与某个架构兼容。
    /// - Parameter arch: 目标架构，不可为 fatFile（传了不会报错，只是语义无意义）
    ///
    /// 判定只有两条：**与自己相同即兼容**，或**自己两者兼具**（`.fatFile` 兼容一切）。
    /// ⚠️ `.unknown` 也走这两条：`.unknown.isCompatiable(with: .unknown)` 为 true，
    /// 即两个「读不出来的文件」会被判成互相兼容，调用方别依赖这个巧合。
    /// ⚠️ 方法名中的 `Compatiable` 是历史拼写错误（正确为 Compatible），
    /// 已有 4 处调用方，改名会破坏它们，故保留。
    public func isCompatiable(with arch: Architecture) -> Bool {
        return self == arch || self == .fatFile
    }
    
    /// 是否与系统架构兼容。
    public func isCompatiableWithSystem() -> Bool {
        return isCompatiable(with: .system)
    }
    
    /// 把清单里书写的架构字符串归一化成枚举值。
    /// 覆盖 Mojang 清单的各种写法（aarch64 / x86 / amd64 …）；
    /// **未识别的字符串一律返回 `.unknown`**（例如部分清单里的 `arm32-v7a`），
    /// 而不是回退成系统架构 —— 调用方据此能判出「这个值我不认识」。
    public static func fromString(_ string: String) -> Architecture {
        switch string {
        case "aarch64", "arm64", "arm": .arm64
        case "x86", "x64", "x86_64", "amd64": .x64
        default: .unknown
        }
    }
}
