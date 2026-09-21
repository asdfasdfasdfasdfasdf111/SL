//
//  MinecraftInstanceVersion.swift
//  PCL.Mac
//
//  实例的版本 / 清单辅助职责（从 MinecraftInstance.swift 逐字搬移，逻辑与文案未变）：
//  - getClientBrand：按清单文本关键字判定加载器品牌
//  - loadManifest：读取并解析客户端清单，同时记录品牌
//  - detectVersion：从客户端 jar 的 version.json 探测版本，失败回退清单 id
//  - getIconName：实例图标名（原版取版本图标，加载器取品牌图标）
//
//  访问级别：loadManifest / detectVersion 由 private 放宽为 internal（主文件 setup() 与 launch() 调用）；
//  getClientBrand 仅本文件 loadManifest 调用，保持 private static。对外接口零变化。
//

import Foundation
import SwiftyJSON
import ZIPFoundation

extension MinecraftInstance {
    private static func getClientBrand(_ manifestString: String) -> ClientBrand {
        if manifestString.contains("neoforged") {
            return .neoforge
        } else if manifestString.contains("fabric") {
            return .fabric
        } else if manifestString.contains("forge") {
            return .forge
        } else {
            return .vanilla
        }
    }

    @discardableResult
    func loadManifest() -> Bool {
        do {
            let manifestPath = runningDirectory.appendingPathComponent(runningDirectory.lastPathComponent + ".json")
            
            // readToEnd 可能返回 nil（空/损坏清单文件），强解包会崩；失败按读取失败处理
            let fh = try FileHandle(forReadingFrom: manifestPath)
            defer { try? fh.close() }
            guard let data = try fh.readToEnd() else {
                err("无法读取 \(manifestPath.lastPathComponent): 文件为空")
                return false
            }
            self.clientBrand = MinecraftInstance.getClientBrand(String(data: data, encoding: .utf8) ?? "")
            
            guard let manifest = try ClientManifest.parse(
                url: manifestPath, minecraftDirectory: minecraftDirectory
            ) else { return false }
            self.manifest = manifest
        } catch {
            err("无法加载客户端清单: \(error.localizedDescription)")
            return false
        }
        
        return true
    }

    func detectVersion() {
        guard version == nil else {
            return
        }
        do {
            let archive = try Archive(url: runningDirectory.appendingPathComponent("\(name).jar"), accessMode: .read)
            guard let entry = archive["version.json"] else {
                throw MyLocalizedError(reason: "version.json 不存在")
            }
            
            var data = Data()
            _ = try archive.extract(entry, consumer: { (chunk) in
                data.append(chunk)
            })
            
            let version = MinecraftVersion(displayName: try JSON(data: data)["id"].stringValue)
            self.version = version
        } catch {
            err("无法检测版本: \(error.localizedDescription)，正在使用清单版本")
            self.version = .init(displayName: manifest.id)
        }
    }

    public func getIconName() -> String {
        if self.clientBrand == .vanilla {
            return self.version.getIconName()
        }
        return "\(self.clientBrand.rawValue.capitalized)Icon"
    }
}
