//
//  MinecraftLauncherArguments.swift
//  PCL.Mac
//
//  启动参数构建（从 MinecraftLauncher.swift 逐字搬移，逻辑、常量与文案未变）：
//  - buildJvmArguments：模板变量、清单 JVM 参数与补齐项（内存 / log4j / natives / GC / 编码）
//  - buildClasspath：依赖库与客户端 jar 的 classpath 拼接
//  - buildGameArguments：游戏参数模板替换与 demo 分支
//
//  访问级别：buildGameArguments 由 private 放宽为 internal（主文件 launch() 调用）；
//  buildClasspath 仅本文件 buildJvmArguments 调用，保持 private。对外接口零变化。
//

import Foundation

extension MinecraftLauncher {
    // MARK: - 内存参数口径（缺陷：内存参数无校验）
    //
    // `maxMemory` 来自实例配置 `.PCL_Mac.json`，是不经校验的持久化值：
    //  - 取 0（或负值 / 极小值）会产出 `-Xmx0m`，JVM 立即以退出码 1 秒退，
    //    在 UI 上被报成「Minecraft 异常退出（退出码 1）」，与真正的游戏崩溃完全不可区分；
    //  - 取超大值（超过物理内存）会让堆分配依赖 swap，表现为长时间卡顿 / 分配失败。
    // 故在构造 `-Xmx` / `-Xms` 前做一次归一化，越界即回退默认值并**显式告知用户**。

    /// 堆上限下界（MB）。
    /// 依据：现代 Minecraft 完成类加载 + 资源加载需要数百 MB，官方帮助页对现代版本的最低建议是 1 GB；
    /// 本启动器取更宽松的 512 MB 作为「明显不是用户本意」的判定线，
    /// 避免把 1024 之类偏小但仍可用的配置误判为非法。
    static let minHeapMB = 512
    /// 堆上限默认值（MB），与 `MinecraftConfig.maxMemory` 的默认值保持一致。
    static let defaultHeapMB = 4096

    /// 本机物理内存（MB），用作堆上限的上界。
    static var physicalMemoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024) }

    /// 校验并归一化堆内存上限（MB）。
    ///
    /// 口径与依据：
    ///  - 下界 `minHeapMB`（512 MB）：见上；
    ///  - 上界 = 物理内存：堆上限超过物理内存必然触发大量 swap 或分配失败，PCL2 的内存上限同样以物理内存为准；
    ///  - 物理内存异常小（< 512 MB）时以 `minHeapMB` 作上界，保证默认值自身不会被判为越界。
    /// 越界时返回默认值（夹到上界内）并置 `didFallback`，由调用方 warn + hint 让回退可见。
    static func sanitizedHeapMB(_ raw: Int32) -> (value: Int, didFallback: Bool) {
        let upper = max(minHeapMB, physicalMemoryMB)
        let requested = Int(raw)
        guard requested >= minHeapMB, requested <= upper else {
            return (min(defaultHeapMB, upper), true)
        }
        return (requested, false)
    }

    public func buildJvmArguments(_ options: LaunchOptions) -> [String] {
        let values: [String: String] = [
            "natives_directory": instance.runningDirectory.appendingPathComponent("natives").path,
            "launcher_name": "PCL.Mac",
            "launcher_version": SharedConstants.shared.version,
            "classpath": buildClasspath(),
            "classpath_separator": ":",
            "library_directory": instance.minecraftDirectory.librariesURL.path,
            "version_name": instance.name,
            "authlib_injector_path": SharedConstants.shared.authlibInjectorURL.path
        ]

        // 1) 先放 yggdrasil 认证参数（离线账号时为空）
        var args: [String] = Array(options.yggdrasilArguments)

        // 2) 动态读取 manifest 中的 JVM 参数（含 Forge/Fabric/NeoForge 清单合并后的结果）
        let manifestJVM = instance.manifest.getArguments().getAllowedJVMArguments()
        args.append(contentsOf: manifestJVM)

        // 3) 动态补齐缺失的关键参数（仅当 manifest 未提供时才追加，避免重复）

        // -Xmx 内存：manifest 一般不含；用户已显式指定（自定义 JVM 参数/高级设置）则不覆盖
        // 取值先经 sanitizedHeapMB 归一化：越界回退默认值，并让「已回退到默认」在日志与提示中可见
        let heap = Self.sanitizedHeapMB(instance.config.maxMemory)
        if heap.didFallback {
            warn("内存上限配置不合法：maxMemory=\(instance.config.maxMemory) MB，可接受范围 \(Self.minHeapMB)~\(Self.physicalMemoryMB) MB（上界为本机物理内存），已回退为 \(heap.value) MB")
            hint("内存上限 \(instance.config.maxMemory) MB 不合法，已自动回退为 \(heap.value) MB。", .critical)
        }
        if !args.contains(where: { $0.contains("-Xmx") }) {
            args.append("-Xmx\(heap.value)m")
        }

        // -Xms 堆初始大小：与 -Xmx 同级避免堆扩张时的 GC 停顿（参考 Swift Craft Launcher）。
        // 默认取 maxMemory 的一半，下限 256m；用户/清单已显式指定则不覆盖。
        // 上界必须夹到堆上限：`-Xms` 大于 `-Xmx` 会让 JVM 直接报
        // "Initial heap size set to a larger value than the maximum heap size" 并退出
        if !args.contains(where: { $0.contains("-Xms") }) {
            let xms = min(heap.value, max(256, heap.value / 2))
            args.append("-Xms\(xms)m")
        }

        // Log4Shell 漏洞防御（对照 PCL2 ModLaunch.vb：老版本 1.18.1 及以下官方 JSON
        // 不携带 -Dlog4j2.formatMsgNoLookups=true，需启动器强制补上，否则日志注入可执行代码）
        if !args.contains(where: { $0.contains("log4j2.formatMsgNoLookups") }) {
            args.append("-Dlog4j2.formatMsgNoLookups=true")
        }

        // -Djava.library.path：LWJGL 加载 native 库必需。官方 1.13+ JSON 自带，
        // 第三方/自定义 JSON 丢失时补齐（对照 PCL2 McLaunchArgumentsJvmOld 强制注入）
        if !args.contains(where: { $0.contains("java.library.path") }) {
            args.append("-Djava.library.path=${natives_directory}")
        }

        // -Djna.tmpdir：若 manifest 未提供则补齐
        let hasJnaTmp = manifestJVM.contains { $0.contains("jna.tmpdir") }
        if !hasJnaTmp {
            args.append("-Djna.tmpdir=${natives_directory}")
        }

        // -cp ${classpath}：若 manifest 未提供则补齐
        let hasClasspath = manifestJVM.contains { $0 == "-cp" } || manifestJVM.contains { $0 == "-classpath" } || manifestJVM.contains { $0.contains("${classpath}") }
        if !hasClasspath {
            args.append(contentsOf: ["-cp", "${classpath}"])
        }

        // 4) 平台/版本适配参数补齐（均先查重，manifest 已有则不重复）
        // macOS LWJGL3 必需：令启动线程成为 AWT 主线程（官方 1.13+ JSON 自带；第三方/自定义 JSON 丢失时补齐）
        let hasStartOnFirstThread = args.contains { $0.contains("XstartOnFirstThread") }
        if !hasStartOnFirstThread {
            args.append("-XstartOnFirstThread")
        }

        // Java 8 及以下默认 GC 为 CMS/Serial，显式启用 G1 改善长卡顿（Java 9+ 默认已是 G1，无需）
        if let javaPath = options.javaPath,
           let javaMajor = MinecraftInstance.readJavaMajorVersion(at: javaPath),
           javaMajor <= 8,
           !args.contains(where: { $0.contains("UseG1GC") }) {
            args.append("-XX:+UseG1GC")
        }

        // Java 9+（默认 G1）：无显式 GC 选择时注入低风险 G1 停顿调优
        // （-XX:+ParallelRefProcEnabled / -XX:MaxGCPauseMillis=200，参考 Swift Craft Launcher balanced 预设），
        // 用户若显式指定了 ZGC/Shenandoah 等其他收集器则整组跳过
        if let javaPath = options.javaPath,
           let javaMajor = MinecraftInstance.readJavaMajorVersion(at: javaPath),
           javaMajor >= 9 {
            let explicitGC = ["UseG1GC", "UseZGC", "UseShenandoahGC", "UseParallelGC", "UseSerialGC", "UseEpsilonGC"]
                .contains { gc in args.contains { $0.contains(gc) } }
            if !explicitGC {
                if !args.contains(where: { $0.contains("ParallelRefProcEnabled") }) {
                    args.append("-XX:+ParallelRefProcEnabled")
                }
                if !args.contains(where: { $0.contains("MaxGCPauseMillis") }) {
                    args.append("-XX:MaxGCPauseMillis=200")
                }
            }
        }

        // 异常热路径优化：重复抛同一异常只保留首次堆栈（-XX:+OmitStackTraceInFastThrow），
        // 字符串拼接改为 StringBuilder 式优化（-XX:+OptimizeStringConcat）；均为零风险参数
        if !args.contains(where: { $0.contains("OmitStackTraceInFastThrow") }) {
            args.append("-XX:+OmitStackTraceInFastThrow")
        }
        if !args.contains(where: { $0.contains("OptimizeStringConcat") }) {
            args.append("-XX:+OptimizeStringConcat")
        }

        // 诊断：OOM 时留下堆转储现场（零运行开销，仅在崩溃时写文件）
        if !args.contains(where: { $0.contains("HeapDumpOnOutOfMemoryError") }) {
            args.append("-XX:+HeapDumpOnOutOfMemoryError")
        }

        // 字符编码一致性：显式声明 UTF-8，避免环境差异导致的乱码
        if !args.contains(where: { $0.contains("file.encoding") }) {
            args.append("-Dfile.encoding=UTF-8")
        }

        return Util.replaceTemplateStrings(args, with: values)
    }
    
    private func buildClasspath() -> String {
        // 去重
        ClientManifest.deduplicateLibraries(instance.manifest)
        
        var urls: [URL] = []
        for library in instance.manifest.getNeededLibraries() {
            if let artifact = library.artifact {
                urls.append(instance.minecraftDirectory.librariesURL.appendingPathComponent(artifact.path))
            }
        }
        urls.append(instance.runningDirectory.appendingPathComponent("\(instance.name).jar"))

        return urls.map { $0.path }.joined(separator: ":")
    }
    
    func buildGameArguments(_ options: LaunchOptions) -> [String] {
        // 用户类型：PCL2 强制所有账号（含离线）传 "msa"（ModLaunch.vb 第 1546 行，issue #1221）。
        // 离线账号若按旧逻辑传 "legacy"，部分 1.20.5+ 服务端/插件按非正版身份处理导致进服异常；
        // 与 PCL2 保持一致即对所有账号统一 "msa"。
        // （注意：离线模式 16 字符用户名校验由 hello 包编码端做，见 buildGameArguments 下方
        //   "auth_player_name" —— 超过 16 字符会抛 EncoderException "String too big"）
        let userType = "msa"
        let values: [String: String] = [
            "auth_player_name": options.playerName,
            "version_name": instance.version!.displayName,
            "game_directory": instance.runningDirectory.path,
            "assets_root": instance.minecraftDirectory.assetsURL.path,
            "assets_index_name": instance.manifest.assetIndex?.id ?? "",
            "auth_uuid": options.uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "auth_access_token": options.accessToken,
            "auth_session": options.accessToken,
            "user_type": userType,
            // version_type：对照 PCL2 ModLaunch.vb（${version_type} = 版本类型，如 release/snapshot）。
            // 旧实现硬编码 "PCL.Mac x" 会污染 F3 调试面板的版本类型显示，改用 manifest.type。
            "version_type": instance.manifest.type.isEmpty ? "release" : instance.manifest.type,
            // user_properties：与 PCL2 一致传 {} （不带引号——Process.arguments 不走 shell，
            // 模板值会原样成为单个参数，带引号反而让 Java 收到字面 "{}"）
            "user_properties": "{}"
        ]
        
        var args: [String] = []
        if options.isDemo {
            args.append("--demo")
        }
        
        return Util.replaceTemplateStrings(instance.manifest.getArguments().getAllowedGameArguments(), with: values) + args
    }
}
