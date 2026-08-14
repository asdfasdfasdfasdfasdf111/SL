//
//  Requests.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/11.
//

import Foundation
import SwiftyJSON

public protocol URLConvertible {
    var url: URL { get }
}

extension URL: URLConvertible {
    public var url: URL { self }
}

extension String: URLConvertible {
    public var url: URL { URL(string: self)! }
}

public enum EncodeMethod {
    case json
    case urlEncoded
}

public struct Response {
    public let data: Data?
    public let json: JSON?
    public let error: Error?
    
    public func getDataOrThrow() throws -> Data {
        // 注意：不能写成 `guard let self.data else` —— SE-0345 简写仅支持简单标识符，
        // 属性路径（self.data）会编译报错 "unwrap condition requires a valid identifier"
        guard let data = self.data else {
            throw self.error ?? NSError(domain: "data 为空", code: -1)
        }
        
        return data
    }
    
    public func getJSONOrThrow() throws -> JSON {
        return try JSON(data: getDataOrThrow())
    }
}

// MARK: - 统一直连会话

extension URLSession {
    /// 启动器统一直连会话（禁用系统/环境代理）：
    /// macOS 的 URLSession 默认走系统代理（如 Clash 127.0.0.1:12002）。实测系统代理对
    /// bmclapi2 / mojang 域名的 TLS 转发失败时，同一 URL 用 curl 直连正常，而 URLSession
    /// 报 "An SSL error has occurred and a secure connection to the server cannot be made."
    /// （NSURLErrorSecureConnectionFailed），且 NetManager 对同一源重试 3 次共耗时 45s 才失败。
    /// 启动器所有下载目标（Mojang 官方 + BMCLAPI 镜像）都支持直连：官方被墙时自动切镜像
    /// （downloadURLs 双源 / DownloadItem fallback），镜像直连国内可达——不依赖用户代理软件，
    /// 代理出口故障不再导致下载 SSL 失败。
    static let direct: URLSession = {
        let c = URLSessionConfiguration.default
        // 空字典 = 不使用任何代理（nil 才是「走系统默认代理」）
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 600
        // 与 NetManager.config.maxSlices(16) 对齐：分片池 16 路并发时不再被
        // 每主机 8 连接卡住一半（此前 16 个分片只有 8 条连接可用，等效最大 8 路并发）。
        // macOS 对 HTTP/1.1 实际连接数有系统上限，但 HTTP/2 多路复用与多主机场景下仍有收益。
        c.httpMaximumConnectionsPerHost = 16
        // HTTP/1.1 环境下对同主机请求启用管线化，减少连接往返等待（PCL2 同样启用）
        c.httpShouldUsePipelining = true
        return URLSession(configuration: c)
    }()
}

public class Requests {
    public static func request(
        url: URL,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: [String: Any]? = nil,
        encodeMethod: EncodeMethod = .json,
        ignoredFailureStatusCodes: [Int]
    ) async -> Response {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = method
            
            headers?.forEach { key, value in
                request.setValue(value, forHTTPHeaderField: key)
            }
            
            if let body = body {
                switch encodeMethod {
                case .json:
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
                case .urlEncoded:
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    if method == "GET" {
                        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                        components.queryItems = body.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
                        request.url = components.url
                    } else {
                        let query = body.map { key, value in
                            "\(key)=\(String(describing: value))"
                        }.joined(separator: "&")
                        request.httpBody = query.data(using: .utf8)
                    }
                }
            }
            
            let (data, response) = try await URLSession.direct.data(for: request)
            if let response = response as? HTTPURLResponse, response.statusCode != 200 && !ignoredFailureStatusCodes.contains(response.statusCode) {
                debug("\(url.absoluteString) 返回了 \(response.statusCode): \(String(data: data, encoding: .utf8) ?? "(empty)")")
            }
            let json = try? JSON(data: data)
            return Response(data: data, json: json, error: nil)
        } catch let error as URLError where error.code == .cancelled {
            return Response(data: nil, json: nil, error: nil)
        } catch {
            err("在发送请求时发生错误: \(error)")
            return Response(data: nil, json: nil, error: error)
        }
    }

    public static func get(
        _ url: URLConvertible,
        headers: [String: String]? = nil,
        body: [String: Any]? = nil,
        encodeMethod: EncodeMethod = .urlEncoded,
        ignoredFailureStatusCodes: [Int] = []
    ) async -> Response {
        return await request(url: url.url, method: "GET", headers: headers, body: body, encodeMethod: encodeMethod, ignoredFailureStatusCodes: ignoredFailureStatusCodes)
    }

    public static func post(
        _ url: URLConvertible,
        headers: [String: String]? = nil,
        body: [String: Any]? = nil,
        encodeMethod: EncodeMethod = .json,
        ignoredFailureStatusCodes: [Int] = []
    ) async -> Response {
        return await request(url: url.url, method: "POST", headers: headers, body: body, encodeMethod: encodeMethod, ignoredFailureStatusCodes: ignoredFailureStatusCodes)
    }
}
