//
//  InstallProgress.swift
//  PCL.Mac
//
//  安装进度词汇（从 InstallTask.swift 逐字搬移，逻辑与文案未变）：
//  - InstallStage：阶段枚举与显示名
//  - InstallState：阶段状态与图标名
//

// MARK: - 安装进度定义
public enum InstallStage: Int {
    case before = 0
    case clientJson = 1
    case clientIndex = 2
    case clientJar = 3
    case clientResources = 4
    case clientLibraries = 5
    case natives = 6
    case end = 7
    
    case installFabric = 1000
    case installForge = 1001
    case installNeoforge = 1002
    
    case customFile = 2000
    case modDownload = 2001
    
    public func getDisplayName() -> String {
        switch self {
        case .before: "未启动"
        case .clientJson: "下载原版 json 文件"
        case .clientJar: "下载原版 jar 文件"
        case .installFabric: "安装 Fabric"
        case .installForge: "安装 Forge"
        case .installNeoforge: "安装 NeoForge"
        case .clientIndex: "下载资源索引文件"
        case .clientResources: "下载散列资源文件"
        case .clientLibraries: "下载依赖项文件"
        case .natives: "下载本地库文件"
        case .customFile: "下载自定义文件"
        case .modDownload: "下载文件"
        case .end: "结束"
        }
    }
}

// MARK: - 安装进度状态定义
public enum InstallState {
    case waiting, inprogress, finished, failed
    public func getImageName() -> String {
        switch self {
        case .waiting:
            "InstallWaiting"
        case .finished:
            "InstallFinished"
        default:
            "Missingno"
        }
    }
}
