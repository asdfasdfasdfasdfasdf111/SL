//
//  Constants.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//

import Foundation

public struct SharedConstants {
    public static let shared = SharedConstants()
    
    public let applicationContentsURL: URL
    public let applicationResourcesURL: URL
    public let logURL: URL
    public let applicationSupportURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SL启动器")
    public let temperatureURL: URL
    public let authlibInjectorURL: URL
    
    public let dateFormatter = DateFormatter()
    
    public let isDevelopment: Bool
    public let version = "Beta 0.1.1"
    public let branch: String
    
    private init() {
        self.applicationContentsURL = Bundle.main.bundleURL.appendingPathComponent("Contents")
        self.applicationResourcesURL = self.applicationContentsURL.appendingPathComponent("Resources")
        self.logURL = applicationSupportURL.appendingPathComponent("Logs").appendingPathComponent("app.log")
        self.temperatureURL = applicationSupportURL.appendingPathComponent("Temp")
        self.authlibInjectorURL = applicationSupportURL.appendingPathComponent("authlib-injector.jar")
        
        self.dateFormatter.dateFormat = "yyyy/MM/dd HH:mm"
        self.dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        
        self.isDevelopment = true
        let branch = Bundle.main.object(forInfoDictionaryKey: "BRANCH") as? String
        self.branch = (branch?.isEmpty ?? true) ? "本地构建" : branch!
    }
}
