//
//  AssetIndex.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/15.
//

import SwiftyJSON
import Foundation

public class AssetIndex {
    public let objects: [Object]
    
    public init(_ json: JSON) {
        self.objects = json["objects"].dictionaryValue.values.map(Object.init)
    }
    
    public init(objects: [Object]) {
        self.objects = objects
    }
    
    public class Object {
        public let hash: String
        public let size: Int32
        
        public init(_ json: JSON) {
            self.hash = json["hash"].stringValue
            self.size = json["size"].int32Value
        }
        
        public func appendTo(_ url: URL) -> URL {
            return url.appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash)
        }
    }
    
    public static func parse(_ data: Data) throws -> AssetIndex {
        let json = try JSON(data: data)
        return AssetIndex(json)
    }
}
