import AlibabaCloudOSS
import Foundation

public enum OssBridgeContract {
    public struct SessionValues {
        public let endpoint: String
        public let region: String
        public let bucket: String
        public let accessKeyId: String
        public let accessKeySecret: String
    }

    public struct StableError {
        public let code: String
        public let message: String
        public let details: [String: Any]?
    }

    public struct ObjectValues {
        public let key: String
        public let size: Int
        public let lastModified: Date?
        public let etag: String?
        public let storageClass: String?

        public init(
            key: String,
            size: Int,
            lastModified: Date? = nil,
            etag: String? = nil,
            storageClass: String? = nil
        ) {
            self.key = key
            self.size = size
            self.lastModified = lastModified
            self.etag = etag
            self.storageClass = storageClass
        }
    }

    public enum BridgeError: Error {
        case invalidRequest
        case invalidMaxBytes
        case invalidObjectKey
        case notConfigured
        case contentTooLarge
        case unknown
    }

    public static func session(_ arguments: [String: Any]) throws -> SessionValues {
        SessionValues(
            endpoint: try string(arguments, "endpoint"),
            region: try string(arguments, "region"),
            bucket: try string(arguments, "bucket"),
            accessKeyId: try string(arguments, "accessKeyId"),
            accessKeySecret: try string(arguments, "accessKeySecret")
        )
    }

    public static func listResult(_ response: ListObjectsV2Result) -> [String: Any] {
        listResult(
            objects: (response.contents ?? []).map { object in
                ObjectValues(
                    key: object.key ?? "",
                    size: object.size ?? 0,
                    lastModified: object.lastModified,
                    etag: object.etag,
                    storageClass: object.storageClass
                )
            },
            commonPrefixes: (response.commonPrefixes ?? []).compactMap(\.prefix),
            isTruncated: response.isTruncated ?? false,
            nextMarker: response.nextContinuationToken
        )
    }

    public static func listResult(
        objects: [ObjectValues],
        commonPrefixes: [String],
        isTruncated: Bool,
        nextMarker: String?
    ) -> [String: Any] {
        var value: [String: Any] = [
            "objects": objects.map { object in
                var value: [String: Any] = [
                    "key": object.key,
                    "size": object.size,
                ]
                if let date = object.lastModified {
                    value["lastModifiedMilliseconds"] = Int64(date.timeIntervalSince1970 * 1000)
                }
                if let etag = object.etag { value["etag"] = etag }
                if let storageClass = object.storageClass { value["storageClass"] = storageClass }
                return value
            },
            "commonPrefixes": commonPrefixes,
            "isTruncated": isTruncated,
        ]
        if let nextMarker {
            value["nextMarker"] = nextMarker
        }
        return value
    }

    public static func progressEvent(
        taskId: String,
        direction: String,
        transferred: Int64,
        total: Int64
    ) -> [String: Any] {
        [
            "taskId": taskId,
            "direction": direction,
            "transferredBytes": max(0, transferred),
            "totalBytes": max(0, total),
        ]
    }

    public static func string(_ arguments: [String: Any], _ name: String) throws -> String {
        guard let value = arguments[name] as? String, !value.isEmpty else {
            throw BridgeError.invalidRequest
        }
        return value
    }

    public static func stableError(_ error: Error) -> StableError {
        if error is CancellationError {
            return StableError(code: "canceled", message: "传输已取消", details: nil)
        }
        if let bridge = error as? BridgeError {
            switch bridge {
            case .contentTooLarge:
                return StableError(
                    code: "invalidRequest",
                    message: "对象内容超过允许上限",
                    details: ["bridgeCode": "contentTooLarge"]
                )
            case .invalidRequest:
                return StableError(
                    code: "invalidRequest",
                    message: "OSS 请求参数无效",
                    details: ["bridgeCode": "invalidRequest"]
                )
            case .notConfigured:
                return StableError(
                    code: "invalidRequest",
                    message: "OSS 请求参数无效",
                    details: ["bridgeCode": "notConfigured"]
                )
            case .invalidMaxBytes, .invalidObjectKey:
                return StableError(
                    code: "invalidRequest",
                    message: "OSS 请求参数无效",
                    details: ["bridgeCode": String(describing: bridge)]
                )
            case .unknown:
                return StableError(code: "unknown", message: "OSS 操作失败", details: nil)
            }
        }
        if let server = error as? ServerError {
            let code: String
            switch server.code {
            case "InvalidAccessKeyId", "SignatureDoesNotMatch": code = "credentialExpired"
            case "AccessDenied": code = "accessDenied"
            case "NoSuchKey", "NoSuchBucket": code = "notFound"
            case "InvalidArgument", "InvalidRequest": code = "invalidRequest"
            default: code = "serviceError"
            }
            return StableError(code: code, message: "OSS 请求失败", details: [
                "statusCode": server.statusCode,
                "ossCode": server.code,
                "requestId": server.requestId,
            ])
        }
        if let client = error as? ClientError {
            let code = client.code.contains("Parameter") ? "invalidRequest" : "networkUnavailable"
            return StableError(
                code: code,
                message: code == "invalidRequest" ? "OSS 请求参数无效" : "网络连接不可用",
                details: ["sdkCode": client.code]
            )
        }
        return StableError(
            code: "unknown",
            message: "OSS 操作失败",
            details: ["nativeErrorType": String(reflecting: type(of: error))]
        )
    }
}
