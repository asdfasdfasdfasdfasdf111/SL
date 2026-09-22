//
//  ClientManifestLibrary.swift
//  SL启动器
//
//  ClientManifest 的依赖库模型（从 ClientManifest.swift 逐字搬移，逻辑与文案未变）：
//  - Library：maven 坐标解析、osx natives 分类器选取与 Hashable 去重键
//
//  嵌套类型经扩展声明于本文件（同 ClientManifestModels.swift 依据）。
//

import Foundation
import SwiftyJSON

extension ClientManifest {
    public class Library: Hashable {
        public var name: String {
            didSet {
                split = name.split(separator: ":").map(String.init)
            }
        }
        private var split: [String]
        // 畸形库名（段数不足）时用空串兜底，杜绝数组越界崩溃（旧实现 split[0]/[1]/[2] 无保护）
        public var groupId: String { split.count >= 1 ? split[0] : "" }
        public var artifactId: String { split.count >= 2 ? split[1] : "" }
        public var version: String { split.count >= 3 ? split[2] : "" }
        public var classifier: String? { split.count >= 4 ? split[3] : nil }
        public let rules: [Rule]
        public let natives: [String: String]
        public let artifact: DownloadInfo?
        public let isNativeLibrary: Bool

        public init?(json: JSON) {
            self.name = json["name"].stringValue
            self.split = name.split(separator: ":").map(String.init)
            if split.isEmpty {
                return nil
            }
            
            if !json["downloads"].exists() {
                self.rules = []
                self.natives = [:]
                let path = Util.toPath(mavenCoordinate: name)
                self.artifact = DownloadInfo(
                    path: path,
                    url: (URL(string: json["url"].stringValue) ?? URL(string: "https://bmclapi2.bangbang93.com/maven")!).appendingPathComponent(path).absoluteString
                )
            } else {
                if split.count >= 2 && split[1] == "launchwrapper" {
                    self.rules = []
                    self.natives = [:]
                    let path = Util.toPath(mavenCoordinate: name)
                    self.artifact = DownloadInfo(path: path, url: URL(string: "https://libraries.minecraft.net")!.appendingPathComponent(path).absoluteString)
                } else {
                    self.rules = json["rules"].arrayValue.map { Rule(json: $0) }
                    self.natives = json["natives"].dictionaryObject as? [String: String] ?? [:]
                    
                    if let classifiers = json["downloads"]["classifiers"].dictionary,
                       let key = natives["osx"],
                       let json = classifiers[key] {
                        self.artifact = DownloadInfo(json: json)
                        self.isNativeLibrary = true
                        return
                    } else {
                        self.artifact = json["downloads"]["artifact"].exists() ? DownloadInfo(json: json["downloads"]["artifact"]) : nil
                    }
                }
            }
            
            self.isNativeLibrary = false
        }
        
        public static func == (lhs: Library, rhs: Library) -> Bool { lhs.name == rhs.name }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
        }
    }
}
