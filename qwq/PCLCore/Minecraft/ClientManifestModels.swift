//
//  ClientManifestModels.swift
//  PCL.Mac
//
//  ClientManifest 的数据传输模型（从 ClientManifest.swift 逐字搬移，逻辑与文案未变）：
//  - AssetIndex：资源索引元数据
//  - DownloadInfo：单文件下载描述（path / sha1 / size / url）
//
//  嵌套类型经扩展声明于本文件（依据 references/swift-language/nested-types.md 与 extensions.md，
//  官方链接 https://docs.swift.org/swift-book/documentation/the-swift-programming-language/nestedtypes/
//  与 .../extensions/：扩展可为已有类型添加嵌套类型）。ClientManifest 的存储属性、
//  初始化器与解析/合并逻辑仍保留在主文件 ClientManifest.swift。对外类型名零变化。
//

import Foundation
import SwiftyJSON

extension ClientManifest {
    public class AssetIndex {
        public let id: String
        public let sha1: String
        public let size: Int
        public let totalSize: Int
        public let url: String
        public init(json: JSON) {
            id = json["id"].stringValue
            sha1 = json["sha1"].stringValue
            size = json["size"].intValue
            totalSize = json["totalSize"].intValue
            url = json["url"].stringValue
        }
    }

    public class DownloadInfo {
        public var path: String
        public let sha1: String?
        public let size: Int?
        public var url: String
        
        public init(json: JSON) {
            path = json["path"].stringValue
            sha1 = json["sha1"].string
            size = json["size"].int
            url = json["url"].stringValue
        }
        
        init(path: String, sha1: String? = nil, size: Int? = nil, url: String) {
            self.path = path
            self.sha1 = sha1
            self.size = size
            self.url = url
        }
    }
}
