//
//  JavaDownloader.swift
//  模块化拆分：Java 运行时下载（从 JavaManager.swift 拆出）
//  Azul Zulu API 优先，失败回退 Microsoft JDK（17/21）
//

import Foundation

enum JavaDownloader {

    /// 下载指定主版本的 JDK 并解压到 basePath，成功后回调 java 可执行文件 URL。
    /// 注意：回调闭包可能在任何线程触发，进度回调已切主线程。
    static func download(version: Int, basePath: URL, arch: String, progressHandler: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        let currentArch = arch == "aarch64" ? "aarch64" : "x64"

        // 使用 Azul Zulu API 搜索可用版本
        let apiURL = "https://api.azul.com/metadata/v1/zulu/packages/?os=macos&archive_type=zip&java_version=\(version)&arch=\(currentArch)&java_package_type=jdk&latest=true"

        guard let url = URL(string: apiURL) else {
            completion(.failure(NSError(domain: "JavaManager", code: -1)))
            return
        }

        URLSession.direct.dataTask(with: url) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(NSError(domain: "JavaManager", code: -2))); return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let pkg = json.first,
                  let downloadURLStr = pkg["download_url"] as? String,
                  let downloadURL = URL(string: downloadURLStr),
                  pkg["name"] is String else {
                // Azul API 失败，回退到 Microsoft JDK
                downloadMicrosoftJDK(version: version, arch: currentArch, basePath: basePath, progressHandler: progressHandler, completion: completion)
                return
            }

            let downloadTask = URLSession.direct.downloadTask(with: downloadURL) { tempURL, _, error in
                if let error = error { completion(.failure(error)); return }
                guard let tempURL = tempURL else { completion(.failure(NSError(domain: "JavaManager", code: -3))); return }

                let targetDir = basePath.appendingPathComponent("jdk-\(version)")
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

                // 解压 zip
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
                    completion(.success(javaURL))
                } else {
                    completion(.failure(NSError(domain: "JavaManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "解压后未找到 Java"])))
                }
            }
            let observation = downloadTask.progress.observe(\.fractionCompleted) { progress, _ in
                DispatchQueue.main.async { progressHandler(progress.fractionCompleted) }
            }
            objc_setAssociatedObject(downloadTask, "progressObserver", observation, .OBJC_ASSOCIATION_RETAIN)
            downloadTask.resume()
        }.resume()
    }

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
            let targetDir = basePath.appendingPathComponent("jdk-\(version)")
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", tempURL.path, "-C", targetDir.path, "--strip-components=1"]
            do {
                try tar.run()
                tar.waitUntilExit()
                if tar.terminationStatus == 0, let javaURL = findJavaExecutable(in: targetDir) {
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
