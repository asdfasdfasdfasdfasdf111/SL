import Foundation

// MARK: - Java 安装器错误

enum JavaInstallerError: Error, LocalizedError {
    case unsupportedArchitecture
    case invalidVersion
    case downloadFailed(underlying: Error? = nil)
    case installationFailed(exitCode: Int32, message: String? = nil)
    case tempDirectoryCreationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "不支持的 CPU 架构（仅支持 Intel x86_64 和 Apple Silicon arm64）"
        case .invalidVersion:
            return "版本号格式无效"
        case .downloadFailed(let underlying):
            return "下载失败\(underlying.map { ": \($0.localizedDescription)" } ?? "")"
        case .installationFailed(let exitCode, let message):
            return "安装失败 (退出码 \(exitCode))\(message.map { ": \($0)" } ?? "")"
        case .tempDirectoryCreationFailed:
            return "无法创建临时目录"
        }
    }
}

// MARK: - Java 安装器

class JavaInstaller {

    static func downloadOnly(version: String, arch: String, progressHandler: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) throws {
        let downloadURL = try makeDownloadURL(version: version, arch: arch)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let pkgPath = tempDir.appendingPathComponent("openjdk-\(version)-\(arch).tar.gz")

        let task = AppContext.shared.downloadSession.downloadTask(with: downloadURL) { tempURL, response, error in
            if let error = error {
                try? FileManager.default.removeItem(at: tempDir)
                completion(.failure(JavaInstallerError.downloadFailed(underlying: error)))
                return
            }
            guard let tempURL = tempURL else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(.failure(JavaInstallerError.downloadFailed()))
                return
            }
            do {
                if FileManager.default.fileExists(atPath: pkgPath.path) {
                    try FileManager.default.removeItem(at: pkgPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: pkgPath)
                completion(.success(pkgPath))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    static func install(version: String = "25.0.3") throws {
        let arch = try detectArchitecture()
        let downloadURL = try makeDownloadURL(version: version, arch: arch)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let pkgPath = tempDir.appendingPathComponent("openjdk-\(version)-\(arch).pkg")

        do {
            try downloadFileSync(from: downloadURL, to: pkgPath)
            try installPackage(at: pkgPath)
        } catch {
            throw error
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Private Helpers

    private static func detectArchitecture() throws -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        switch machine {
        case "x86_64": return "x64"
        case "arm64": return "aarch64"
        default: throw JavaInstallerError.unsupportedArchitecture
        }
    }

    private static func makeDownloadURL(version: String, arch: String) throws -> URL {
        let versionPattern = #"^\d+\.\d+(\.\d+)?$"#
        guard version.range(of: versionPattern, options: .regularExpression) != nil else {
            throw JavaInstallerError.invalidVersion
        }
        let urlString = "https://aka.ms/download-jdk/microsoft-jdk-\(version)-macos-\(arch).tar.gz"
        guard let url = URL(string: urlString) else {
            throw JavaInstallerError.invalidVersion
        }
        return url
    }

    private static func downloadFileSync(from url: URL, to destination: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?

        let task = AppContext.shared.downloadSession.downloadTask(with: url) { tempURL, response, error in
            defer { semaphore.signal() }
            if let error = error {
                downloadError = error
                return
            }
            guard let tempURL = tempURL else {
                downloadError = URLError(.badServerResponse)
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
            } catch {
                downloadError = error
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 300)

        if let error = downloadError {
            throw JavaInstallerError.downloadFailed(underlying: error)
        }
    }

    private static func installPackage(at pkgPath: URL) throws {
        let script = """
        do shell script "installer -pkg '\(pkgPath.path)' -target /" with administrator privileges
        """
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            throw JavaInstallerError.installationFailed(exitCode: -1, message: "无法创建 AppleScript")
        }
        scriptObject.executeAndReturnError(&error)
        if let errorDict = error {
            let errorMsg = errorDict.description
            throw JavaInstallerError.installationFailed(exitCode: -1, message: errorMsg)
        }
    }
}