//
//  ClientManifest.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//

import Foundation
import SwiftyJSON

public class ClientManifest {
    public let id: String
    public var mainClass: String
    public let type: String
    public let assetIndex: AssetIndex?
    public let assets: String
    public var libraries: [Library]
    public let arguments: Arguments?
    public var minecraftArguments: String?
    public let javaVersion: Int?
    public let clientDownload: DownloadInfo?
    public let clientMappingsDownload: DownloadInfo?

    private init?(json: JSON) {
        self.id = json["id"].stringValue
        self.mainClass = json["mainClass"].stringValue
        self.type = json["type"].stringValue
        self.assets = json["assets"].stringValue
        self.assetIndex = json["assetIndex"].exists() ? AssetIndex(json: json["assetIndex"]) : nil
        self.libraries = json["libraries"].arrayValue.compactMap(Library.init(json:)).filter { Rule.check($0.rules) }
        self.arguments = json["arguments"].exists() ? Arguments(json: json["arguments"]) : nil
        self.minecraftArguments = json["minecraftArguments"].string
        self.javaVersion = json["javaVersion"]["majorVersion"].int
        self.clientDownload = json["downloads"]["client"].exists() ? .init(json: json["downloads"]["client"]) : nil
        self.clientMappingsDownload = json["downloads"]["client_mappings"].exists() ? .init(json: json["downloads"]["client_mappings"]) : nil
    }

    /// 尝试解析与自动合并客户端清单，不会对实例进行操作
    /// - Parameter url: 清单路径
    /// - Parameter minecraftDirectory: 若需自动合并，该参数的值为实例所在的 minecraft 目录，否则为空
    public static func parse(url: URL, minecraftDirectory: MinecraftDirectory? = nil, depth: Int = 0) throws -> ClientManifest? {
        guard depth < 16 else {
            err("inheritsFrom 递归深度超过 16，疑似循环引用")
            return nil
        }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let data = (try? fh.readToEnd()) ?? Data()
        let json = try JSON(data: data)
        
        if json["loader"].exists() && json["intermediary"].exists() && !json["id"].exists() { // 旧版 PCL.Mac Fabric 安装逻辑
            warn("无法解析旧版 PCL.Mac 安装的 Fabric 版本: \(url.lastPathComponent)")
            return nil
        }
        
        if let inheritsFrom = json["inheritsFrom"].string,
           let minecraftDirectory = minecraftDirectory {
            let parentURL = minecraftDirectory.versionsURL.appendingPathComponent(inheritsFrom).appendingPathComponent("\(inheritsFrom).json")
            
            guard FileManager.default.fileExists(atPath: parentURL.path) else {
                err("\(url.path) 中有 inheritsFrom 字段，但其对应的 JSON 不存在")
                return nil
            }
            
            guard let manifest = ClientManifest(json: json) else { return nil }
            let parent: ClientManifest
            do {
                guard let parsedParent = try ClientManifest.parse(url: parentURL, minecraftDirectory: minecraftDirectory, depth: depth + 1) else { return nil }
                parent = parsedParent
            } catch {
                // 父清单存在但无法解析（文件损坏 / 读取失败 / 上游 JSON 非法）时不能再跳过合并：
                // 合并是补齐父版本 libraries 与 arguments 的唯一途径，缺失父清单会得到一份
                // classpath 不完整的清单，进游戏后才以 NoClassDefFoundError 之形式暴露，难以定位。
                // 与「父 JSON 不存在 → return nil」保持一致判定为解析失败，此处向上抛出原始错误
                // （parse 本身即 throws，JSON 层错误同样以抛出方式上报），不返回缺库的清单。
                // 注意：不要退回 break/跳过合并的写法。
                err("无法解析父版本清单 \(parentURL.path)（\(url.lastPathComponent) 的 inheritsFrom=\(inheritsFrom)）: \(error.localizedDescription)")
                throw error
            }
            
            return merge(parent: parent, manifest: manifest)
        }
        return ClientManifest(json: json)
    }
    
    public static func deduplicateLibraries(_ manifest: ClientManifest) {
        // 修正 libraries
        ArtifactVersionMapper.map(manifest, arch: .x64)
        
        var librarySet: Set<HashableLibrary> = .init()
        manifest.libraries = manifest.libraries.filter { librarySet.insert(.init($0)).inserted }
    }
    
    private static func merge(parent: ClientManifest, manifest: ClientManifest) -> ClientManifest {
        parent.libraries.insert(contentsOf: manifest.libraries, at: 0)
        deduplicateLibraries(parent)
        
        parent.arguments?.game.append(contentsOf: manifest.arguments?.game ?? [])
        parent.arguments?.jvm.append(contentsOf: manifest.arguments?.jvm ?? [])
        parent.minecraftArguments = manifest.minecraftArguments
        parent.mainClass = manifest.mainClass
        
        return parent
    }

    public func getNeededLibraries() -> [Library] {
        getAllowedLibraries().filter { !$0.isNativeLibrary }
    }
    
    /// 解析期已按 `allow` / `disallow` 规则筛选完毕的库列表，即「规则允许使用的库」。
    ///
    /// 规则判定集中在 `ClientManifest.init(json:)` 的 `Rule.check` 一处完成，故本方法按设计
    /// 等价于 `libraries` 的恒等返回，不做二次过滤：重复过滤不改变结果，只会让规则判定
    /// 出现第二个入口。名称沿用上游 PCL.Mac 同源实现，含义是「已通过规则筛选」而非
    /// 「此处再筛一遍」。natives 与普通库的区分由 getNeededLibraries / getNeededNatives 承担。
    public func getAllowedLibraries() -> [Library] { libraries }
    
    public func getNeededNatives() -> [Library: DownloadInfo] {
        var result: [Library: DownloadInfo] = [:]
        for library in getAllowedLibraries() {
            if library.isNativeLibrary {
                result[library] = library.artifact
            }
        }
        return result
    }
    
    public func getArguments() -> Arguments {
        if let arguments = self.arguments {
            return arguments
        } else if let minecraftArguments = self.minecraftArguments {
            let gameArgs = minecraftArguments.split(separator: " ").map { Arguments.GameArgument(json: JSON(stringLiteral: String($0))) }
            let jvmArgs: [Arguments.JvmArgument] = [
                "-XX:+UnlockExperimentalVMOptions", "-XX:+UseG1GC", "-XX:-UseAdaptiveSizePolicy", "-XX:-OmitStackTraceInFastThrow",
                "-Djava.library.path=${natives_directory}",
                "-Dorg.lwjgl.system.SharedLibraryExtractPath=${natives_directory}",
                "-Dio.netty.native.workdir=${natives_directory}",
                "-Djna.tmpdir=${natives_directory}",
                "-cp", "${classpath}"
            ].map { Arguments.JvmArgument(json: JSON(stringLiteral: $0)) }
            return Arguments(game: gameArgs, jvm: jvmArgs)
        } else {
            return Arguments(game: [], jvm: [])
        }
    }
    
    private class HashableLibrary: Hashable {
        private let library: Library
        
        init(_ library: Library) {
            self.library = library
        }
        
        static func == (lhs: HashableLibrary, rhs: HashableLibrary) -> Bool {
            lhs.library.groupId == rhs.library.groupId
            && lhs.library.artifactId == rhs.library.artifactId
            && lhs.library.classifier == rhs.library.classifier
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(library.groupId)
            hasher.combine(library.artifactId)
            hasher.combine(library.classifier)
        }
    }
}
