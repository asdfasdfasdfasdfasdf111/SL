//
//  JavaDownloader.swift
//  模块化拆分：Java 运行时下载（从 JavaManager.swift 拆出）
//  Azul Zulu API 优先，失败回退 Microsoft JDK（17/21）
//

//
//  JavaDownloader.swift
//  模块化拆分：Java 运行时下载（从 JavaManager.swift 拆出）
//  Azul Zulu API 优先，失败回退 Microsoft JDK（17/21）
//
//  两条链路结构一致：「下到系统临时文件 → 解压到 <basePath>/jdk-<版本> → 找 bin/java」：
//    Azul → zip，用 /usr/bin/unzip
//    MS   → tar.gz，用 /usr/bin/tar（--strip-components=1 去掉包内顶层目录）
//
//  ⚠️ 失败时靠 `defer { if !success { removeItem(targetDir) } }` 清理半成品 ——
//  所以 targetDir 是**整个被删掉**，不会留下解压到一半的文件给下次复用。
//
//  ⚠️ 用 `URLSession.direct`（不走代理的会话）而非 `AppContext.shared.apiSession`：
//  JDK 包在境外 CDN，走启动器统一代理反而更容易失败。
//

import Foundation

/// Java 运行时（JDK）下载器（全部静态方法，无状态）。
enum JavaDownloader {

    /// 下载指定主版本的 JDK 并解压到 basePath，成功后回调 java 可执行文件 URL。
    /// 注意：回调闭包可能在任何线程触发，进度回调已切主线程。
    ///
    /// - Parameter arch: 只区分 `"aarch64"` 与其它（其它一律当 `x64`）——
    ///   传 "x64" / "unknown" 得到的都是 x64 包。
    /// - Parameter completion: **只会被调用一次**；Azul 查不到包时会转去下 Microsoft JDK
    ///   并沿用同一个 completion，所以调用方不会收到两次回调。
    /// ⚠️ basePath 下的目标目录名固定是 `jdk-<主版本>`：重复下载同一版本会写进同一目录。
    static func download(version: Int, basePath: URL, arch: String, progressHandler: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        // 二值化：只认 aarch64，其余全按 x64 处理
        //（把 "unknown" 原样拼进 URL 只会拿到 404）。
        let currentArch = arch == "aarch64" ? "aarch64" : "x64"

        // 使用 Azul Zulu API 搜索可用版本
        // `latest=true` + 取数组第一项 = 该主版本下最新的一个 Zulu 包。
        // 其余参数：os=macos（只要 macOS 包）、archive_type=zip（后面用 unzip 解）、
        // java_package_type=jdk（要 JDK 不要 JRE —— 需要带 javac）。
        let apiURL = "https://api.azul.com/metadata/v1/zulu/packages/?os=macos&archive_type=zip&java_version=\(version)&arch=\(currentArch)&java_package_type=jdk&latest=true"

        guard let url = URL(string: apiURL) else {
            completion(.failure(NSError(domain: "JavaManager", code: -1)))
            return
        }

        // 第一步：查 Azul 有哪些包。只发一次 GET，拿到 JSON 数组后取第一条。
        URLSession.direct.dataTask(with: url) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(NSError(domain: "JavaManager", code: -2))); return }

            // 解析失败 / 数组为空 / 缺 download_url / 缺 name —— 任一不满足都视为
            // 「Azul 这边拿不到包」，转 Microsoft 兜底（而不是直接向调用方报错）。
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let pkg = json.first,
                  let downloadURLStr = pkg["download_url"] as? String,
                  let downloadURL = URL(string: downloadURLStr),
                  pkg["name"] is String else {
                // Azul API 失败，回退到 Microsoft JDK
                downloadMicrosoftJDK(version: version, arch: currentArch, basePath: basePath, progressHandler: progressHandler, completion: completion)
                return
            }

            // 第二步：下载 zip。URLSession 先落在系统临时目录，本方法只负责解压与搬移。
            let downloadTask = URLSession.direct.downloadTask(with: downloadURL) { tempURL, _, error in
                if let error = error { completion(.failure(error)); return }
                guard let tempURL = tempURL else { completion(.failure(NSError(domain: "JavaManager", code: -3))); return }

                let targetDir = basePath.appendingPathComponent("jdk-\(version)")
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                // success 与 defer 配对：只有后面真的找到 bin/java 才置 true，
                // 否则整个 targetDir 被删掉 —— 不留半成品给下次调用复用。
                var success = false
                defer { if !success { try? FileManager.default.removeItem(at: targetDir) } }

                // 解压 zip
                // `-o` 覆盖已存在文件。用系统 unzip 而不是 ZIPFoundation：
                // jdk 包里有符号链接，系统工具的处理最稳妥。
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-o", tempURL.path, "-d", targetDir.path]
                do {
                    try unzip.run()
                    unzip.waitUntilExit()
                } catch {
                    completion(.failure(error))
                    return
                }

                // 查找解压后的 java 可执行文件
                if let javaURL = findJavaExecutable(in: targetDir) {
                    success = true
                    completion(.success(javaURL))
                } else {
                    completion(.failure(NSError(domain: "JavaManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "解压后未找到 Java"])))
                }
            }
            // progress 的 KVO observation 必须**被强引用持有**，否则会被立刻释放、进度不再回调。
            // URLSession 任务是 Objective-C 对象，用 associated object 挂上去最省事
            //（任务释放时 observation 随之释放，不用手工摘除）。
            let observation = downloadTask.progress.observe(\.fractionCompleted) { progress, _ in
                // 观察回调可能在任意线程 —— 切主线程再交给 UI。
                DispatchQueue.main.async { progressHandler(progress.fractionCompleted) }
            }
            objc_setAssociatedObject(downloadTask, "progressObserver", observation, .OBJC_ASSOCIATION_RETAIN)
            downloadTask.resume()
        }.resume()
    }

    /// Microsoft JDK 兜底链路（仅 Azul 查不到包时才走到）。
    /// ⚠️ **只支持 17 与 21** —— 其它版本直接回调「不支持的 Java 版本」，
    /// 不会再去猜别的下载源。下载地址是 `aka.ms` 短链，按「版本 × 架构」硬编码。
    private static func downloadMicrosoftJDK(version: Int, arch: String, basePath: URL, progressHandler: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        let urlString: String
        if version == 17 {
            urlString = arch == "aarch64" ? "https://aka.ms/download-jdk/microsoft-jdk-17-macOS-aarch64.tar.gz" : "https://aka.ms/download-jdk/microsoft-jdk-17-macOS-x64.tar.gz"
        } else if version == 21 {
            urlString = arch == "aarch64" ? "https://aka.ms/download-jdk/microsoft-jdk-21-macOS-aarch64.tar.gz" : "https://aka.ms/download-jdk/microsoft-jdk-21-macOS-x64.tar.gz"
        } else {
            completion(.failure(NSError(domain: "JavaManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "不支持的 Java 版本"])))
            return
        }
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "JavaManager", code: -2)))
            return
        }
        let downloadTask = URLSession.direct.downloadTask(with: url) { tempURL, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let tempURL = tempURL else { completion(.failure(NSError(domain: "JavaManager", code: -3))); return }
            // 目标目录固定 `jdk-<主版本>`；目录已存在也不清空（后面的 tar 会覆盖）。
            let targetDir = basePath.appendingPathComponent("jdk-\(version)")
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            var success = false
            defer { if !success { try? FileManager.default.removeItem(at: targetDir) } }
            // MS 包是 tar.gz，用系统 tar；`--strip-components=1` 去掉包内那层顶层目录，
            // 让 bin/java 直接落在 targetDir 下（与 Azul 的 zip 解压结果保持同一层级）。
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", tempURL.path, "-C", targetDir.path, "--strip-components=1"]
            do {
                try tar.run()
                // 与 Azul 支路不同：这里显式检查 `terminationStatus == 0`
                //（Azul 支路只看能不能找到 bin/java）。
                tar.waitUntilExit()
                if tar.terminationStatus == 0, let javaURL = findJavaExecutable(in: targetDir) {
                    success = true
                    completion(.success(javaURL))
                } else {
                    completion(.failure(NSError(domain: "JavaManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "解压失败"])))
                }
            } catch { completion(.failure(error)) }
        }
        let observation = downloadTask.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async { progressHandler(progress.fractionCompleted) }
        }
        objc_setAssociatedObject(downloadTask, "progressObserver", observation, .OBJC_ASSOCIATION_RETAIN)
        downloadTask.resume()
    }

    /// 在解压后的目录里递归找第一个可执行的 `java`。
    /// ⚠️ 返回的是**递归遇到的第一个**（enumerator 的深度优先顺序），不做「取最新/最合适」
    /// 之类的挑拣 —— 正常 JDK 包里只有一份 bin/java，够用。
    private static func findJavaExecutable(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "java" && FileManager.default.isExecutableFile(atPath: fileURL.path) {
                return fileURL
            }
        }
        return nil
    }
}
