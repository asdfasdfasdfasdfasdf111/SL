//
//  LoaderSupportProbe.swift
//  PCL.Mac
//
//  加载器支持的联网探测（从 LoaderSupportChecker.swift 逐字搬移，端点、超时与结论语义未变）：
//  - metaSession：meta API 专用直连会话（4s 请求 / 6s 资源超时）
//  - detectAndMergeStates：缓存定论 + 未定论项并发检测，每项定论立即写缓存并广播
//  - key(for:) / checkLoaderSupport：显示名 → 端点 key，以及端点规则表与双源延迟并发
//  - requestOnce：单次请求与「权威空结果 vs 结果未知」判定
//  - 检测响应数组缓存：供 LoaderVersionResolver 复用（下载解析免二次请求）
//

import Foundation

extension LoaderSupportChecker {

    // MARK: - 共享元数据直连会话（全局复用，避免每次检测新建 URLSession 浪费 TCP/TLS 握手）

    /// 加载器 meta API 专用会话：4s 请求 / 6s 资源超时（列表展示，单请求、不重试，
    /// 双源延迟并发兜底；不再为前台列表等待两轮 8s 超时），禁系统代理直连。
    private static let metaSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [:]
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.httpShouldUsePipelining = true
        return URLSession(configuration: cfg)
    }()

    // MARK: - 网络检测

    private enum LoaderCheckResult {
        case supported
        case notSupported
        case failed
    }

    /// 缓存定论 + 未定论项并发检测 → 全量状态；每项定论立即写单加载器缓存（unavailable 不写）
    /// 访问级别为 internal：in-flight 任务创建处（LoaderSupportChecker.swift）调用。
    static func detectAndMergeStates(for version: String) async -> [String: LoaderState] {
        var states = cachedLoaderStates(for: version) ?? [:]

        let missing = candidateDisplayNames(for: version).filter { name in
            states[name] == nil || states[name] == .unavailable
        }
        guard !missing.isEmpty else { return states }

        await withTaskGroup(of: (String, LoaderCheckResult).self) { group in
            for name in missing {
                group.addTask {
                    let key = key(for: name)
                    let result = await checkLoaderSupport(key: key, version: version)
                    return (name, result)
                }
            }
            for await (name, result) in group {
                switch result {
                case .supported:
                    states[name] = .supported
                    writeEntry(version: version, loader: name, state: .supported)
                case .notSupported:
                    states[name] = .notSupported
                    writeEntry(version: version, loader: name, state: .notSupported)
                case .failed:
                    states[name] = .unavailable
                    // 不写缓存：下次只重查该未定论项
                }
                // 真流式：TaskGroup 每完成一个加载器就立即广播，不等其余端点结束。
                if let state = states[name] {
                    publishInflight(version: version, loader: name, state: state)
                }
            }
        }
        return states
    }

    /// 显示名 → 检测端点 key（纯函数，显式 nonisolated 防并发闭包隔离推断误判）
    private nonisolated static func key(for display: String) -> String {
        switch display {
        case "Fabric": return "fabric"
        case "Forge": return "forge"
        case "NeoForged": return "neoforge"
        case "Quilt": return "quilt"
        default: return display.lowercased()
        }
    }

    /// 检查单个加载器对某版本是否可用：单请求（4s 超时）；双源加载器 700ms 延迟并发备用源。
    /// 结论语义：权威源 404/410/空数组 = 明确不支持（notSupported）；网络错误或 5xx = failed（结果未知）。
    /// 快照版本的结果一律视为未知（notSupported 结论不适用于未列出的实验版本）。
    /// 注意：Forge / NeoForged 当前只有 bmclapi 镜像源，按「镜像非权威」口径二者不再产生
    /// notSupported 定论——镜像返回空即视为结果未知（unavailable，不入缓存，下次重查）。
    private static func checkLoaderSupport(key: String, version: String) async -> LoaderCheckResult {
        let encoded = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? version
        var urls: [(URL, Bool)] = []   // (url, 空结果是否权威：官方源权威，镜像非权威不误伤)
        switch key {
        case "fabric":
            urls = [
                (URL(string: "https://meta.fabricmc.net/v2/versions/loader/\(encoded)")!, true),
                (URL(string: "https://bmclapi2.bangbang93.com/fabric-meta/v2/versions/loader/\(encoded)")!, false)
            ]
        case "forge":
            // 单源即镜像：镜像 404 / 空数组可能来自镜像同步滞后或上游抓取异常，
            // 不构成「该版本无 Forge」的权威结论，故与 fabric / quilt 的镜像口径一致（false），
            // 避免镜像空结果被当作 notSupported 长期缓存（7 天）而误报「不支持」。
            urls = [(URL(string: "https://bmclapi2.bangbang93.com/forge/minecraft/\(encoded)")!, false)]
        case "neoforge":
            // 同上：单源镜像，空结果按结果未知处理。
            urls = [(URL(string: "https://bmclapi2.bangbang93.com/neoforge/list/\(encoded)")!, false)]
        case "quilt":
            urls = [
                (URL(string: "https://meta.quiltmc.org/v3/versions/loader/\(encoded)")!, true),
                (URL(string: "https://bmclapi2.bangbang93.com/quilt-meta/v3/versions/loader/\(encoded)")!, false)
            ]
        default:
            return .notSupported
        }
        guard !urls.isEmpty else { return .notSupported }

        if urls.count == 1 {
            return await requestOnce(url: urls[0].0, authoritativeEmpty: urls[0].1, key: key, version: version)
        }

        // 双源：主源立即请求；700ms 后主源仍无结论则并行发起备用源（不等主源完整超时）。
        // 任意源 supported / 权威 notSupported → 立即定论（withTaskGroup 离开时自动取消未完成 child）
        return await withTaskGroup(of: LoaderCheckResult.self) { group in
            group.addTask {
                await requestOnce(url: urls[0].0, authoritativeEmpty: urls[0].1, key: key, version: version)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return .failed }
                return await requestOnce(url: urls[1].0, authoritativeEmpty: urls[1].1, key: key, version: version)
            }
            for await result in group {
                switch result {
                case .supported: return .supported
                case .notSupported: return .notSupported
                case .failed: break
                }
            }
            return .failed
        }
    }

    /// 单次请求（不重试）：200 + 非空数组 = supported（并缓存响应数组）；权威源 4xx/空数组 = notSupported；
    /// 网络错误/5xx/镜像空结果 = failed（结果未知，绝不误判「不支持」）
    private static func requestOnce(url: URL, authoritativeEmpty: Bool, key: String, version: String) async -> LoaderCheckResult {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await metaSession.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // 仅 404/410 = 权威「不存在」；401/403/408/429 等均是鉴权、超时或限流，
                // 必须视为 unavailable，绝不能缓存成「不支持」。
                if (http.statusCode == 404 || http.statusCode == 410), authoritativeEmpty {
                    return isSnapshotVersion(version) ? .failed : .notSupported
                }
                return .failed
            }
            guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else { return .failed }
            if array.isEmpty {
                if authoritativeEmpty {
                    return isSnapshotVersion(version) ? .failed : .notSupported
                }
                return .failed
            }
            storeVersionList(loader: key, mc: version, data: data)
            return .supported
        } catch {
            return .failed
        }
    }

    // MARK: - 检测响应数组缓存（供 LoaderVersionResolver 复用，下载解析免二次请求）

    private static var versionListCache: [String: Data] = [:]
    private static let versionListLock = NSLock()

    private static func storeVersionList(loader: String, mc: String, data: Data) {
        versionListLock.lock()
        versionListCache["\(loader)|\(mc)"] = data
        versionListLock.unlock()
    }

    /// 读取检测阶段缓存的加载器版本数组（原始响应），nil = 未检测过
    public static func cachedVersionList(loader: String, mc: String) -> Data? {
        versionListLock.lock()
        defer { versionListLock.unlock() }
        return versionListCache["\(loader)|\(mc)"]
    }

    /// 清空检测响应数组缓存（供 LoaderSupportChecker.clearMemoryCache 调用）
    static func clearVersionListCache() {
        versionListLock.lock()
        versionListCache = [:]
        versionListLock.unlock()
    }
}
