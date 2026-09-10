import AlibabaCloudOSS
import Cocoa
import FlutterMacOS
import private_domain_oss_contract

public final class PrivateDomainOssPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var client: Client?
    private var bucket: String?
    private var eventSink: FlutterEventSink?
    private var transfers: [String: Task<Void, Never>] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: "private_domain_oss/methods",
            binaryMessenger: registrar.messenger
        )
        let events = FlutterEventChannel(
            name: "private_domain_oss/transfers",
            binaryMessenger: registrar.messenger
        )
        let instance = PrivateDomainOssPlugin()
        registrar.addMethodCallDelegate(instance, channel: methods)
        events.setStreamHandler(instance)
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        do {
            switch call.method {
            case "configure":
                try configure(arguments)
                result(nil)
            case "clearConfiguration":
                clearConfiguration()
                result(nil)
            case "cancelTransfer":
                let taskId = try OssBridgeContract.string(arguments, "taskId")
                transfers[taskId]?.cancel()
                result(nil)
            case "listObjects":
                perform(result) { try await self.listObjects(arguments) }
            case "putEmptyObject":
                perform(result) { try await self.putEmptyObject(arguments); return nil }
            case "deleteObject":
                perform(result) { try await self.deleteObject(arguments); return nil }
            case "deleteObjects":
                perform(result) { try await self.deleteObjects(arguments) }
            case "copyObject":
                perform(result) { try await self.copyObject(arguments); return nil }
            case "uploadFile":
                startTransfer(arguments, result: result, operation: uploadFile)
            case "downloadFile":
                startTransfer(arguments, result: result, operation: downloadFile)
            case "getObjectBytes":
                perform(result) {
                    FlutterStandardTypedData(bytes: try await self.getObjectBytes(arguments))
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch {
            result(Self.flutterError(error))
        }
    }

    private func configure(_ arguments: [String: Any]) throws {
        let values = try OssBridgeContract.session(arguments)
        let credentials = StaticCredentialsProvider(
            accessKeyId: values.accessKeyId,
            accessKeySecret: values.accessKeySecret,
            securityToken: values.securityToken
        )
        let configuration = Configuration.default()
            .withCredentialsProvider(credentials)
            .withRegion(values.region)
            .withEndpoint(values.endpoint)
        client = Client(configuration)
        bucket = values.bucket
        NSLog("PDD OSS configure completed")
    }

    private func clearConfiguration() {
        NSLog("PDD OSS configuration cleared")
        transfers.values.forEach { $0.cancel() }
        transfers.removeAll()
        client = nil
        bucket = nil
    }

    private func listObjects(_ arguments: [String: Any]) async throws -> [String: Any] {
        let (client, bucket) = try session()
        let response = try await client.listObjectsV2(ListObjectsV2Request(
            bucket: bucket,
            delimiter: arguments["delimiter"] as? String,
            maxKeys: arguments["maxKeys"] as? Int ?? 1000,
            prefix: arguments["prefix"] as? String ?? "",
            continuationToken: arguments["marker"] as? String
        ))
        return OssBridgeContract.listResult(response)
    }

    private func putEmptyObject(_ arguments: [String: Any]) async throws {
        let (client, bucket) = try session()
        _ = try await client.putObject(PutObjectRequest(
            bucket: bucket,
            key: try OssBridgeContract.string(arguments, "key"),
            body: .empty
        ))
    }

    private func deleteObject(_ arguments: [String: Any]) async throws {
        let (client, bucket) = try session()
        _ = try await client.deleteObject(DeleteObjectRequest(
            bucket: bucket,
            key: try OssBridgeContract.string(arguments, "key")
        ))
    }

    private func deleteObjects(_ arguments: [String: Any]) async throws -> [String: Any] {
        let (client, bucket) = try session()
        guard let keys = arguments["keys"] as? [String] else {
            throw OssBridgeContract.BridgeError.invalidRequest
        }
        let response = try await client.deleteMultipleObjects(DeleteMultipleObjectsRequest(
            bucket: bucket,
            delete: Delete(quiet: false, objects: keys.map { DeleteObject(key: $0) })
        ))
        let deleted = (response.deletedObjects ?? []).compactMap(\.key)
        return ["deletedKeys": deleted.isEmpty ? keys : deleted, "failedKeys": [String]()]
    }

    private func copyObject(_ arguments: [String: Any]) async throws {
        let (client, bucket) = try session()
        _ = try await client.copyObject(CopyObjectRequest(
            bucket: bucket,
            key: try OssBridgeContract.string(arguments, "to"),
            sourceBucket: bucket,
            sourceKey: try OssBridgeContract.string(arguments, "from")
        ))
    }

    private func uploadFile(_ arguments: [String: Any]) async throws {
        let taskId = try OssBridgeContract.string(arguments, "taskId")
        let key = try OssBridgeContract.string(arguments, "key")
        let path = try OssBridgeContract.string(arguments, "localPath")
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw OssBridgeContract.BridgeError.invalidRequest
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let threshold = (arguments["multipartThresholdBytes"] as? NSNumber)?.int64Value
            ?? 16 * 1024 * 1024
        let (client, bucket) = try session()
        if fileSize >= threshold {
            try await multipartUpload(
                client: client,
                bucket: bucket,
                key: key,
                fileURL: fileURL,
                fileSize: fileSize,
                taskId: taskId
            )
        } else {
            let progress = ProgressClosure { [weak self] _, transferred, total in
                self?.emitProgress(taskId, "upload", transferred, total)
            }
            _ = try await client.putObject(PutObjectRequest(
                bucket: bucket,
                key: key,
                body: .file(fileURL),
                progress: progress
            ))
        }
    }

    private func multipartUpload(
        client: Client,
        bucket: String,
        key: String,
        fileURL: URL,
        fileSize: Int64,
        taskId: String
    ) async throws {
        let initiated = try await client.initiateMultipartUpload(
            InitiateMultipartUploadRequest(bucket: bucket, key: key)
        )
        guard let uploadId = initiated.uploadId else {
            throw OssBridgeContract.BridgeError.unknown
        }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let partSize = 8 * 1024 * 1024
            var uploaded: Int64 = 0
            var partNumber = 1
            var parts: [UploadPart] = []
            while true {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: partSize) ?? Data()
                if data.isEmpty { break }
                let base = uploaded
                let progress = ProgressClosure { [weak self] _, partTransferred, _ in
                    self?.emitProgress(taskId, "upload", base + partTransferred, fileSize)
                }
                let response = try await client.uploadPart(UploadPartRequest(
                    bucket: bucket,
                    key: key,
                    partNumber: partNumber,
                    uploadId: uploadId,
                    body: .data(data),
                    progress: progress
                ))
                guard let etag = response.etag else {
                    throw OssBridgeContract.BridgeError.unknown
                }
                parts.append(UploadPart(etag: etag, partNumber: partNumber))
                uploaded += Int64(data.count)
                emitProgress(taskId, "upload", uploaded, fileSize)
                partNumber += 1
            }
            try Task.checkCancellation()
            _ = try await client.completeMultipartUpload(CompleteMultipartUploadRequest(
                bucket: bucket,
                key: key,
                uploadId: uploadId,
                completeMultipartUpload: CompleteMultipartUpload(parts: parts)
            ))
        } catch {
            _ = try? await client.abortMultipartUpload(AbortMultipartUploadRequest(
                bucket: bucket,
                key: key,
                uploadId: uploadId
            ))
            throw error
        }
    }

    @available(macOS 12.0, *)
    private func downloadFile(_ arguments: [String: Any]) async throws {
        let taskId = try OssBridgeContract.string(arguments, "taskId")
        let targetURL = URL(
            fileURLWithPath: try OssBridgeContract.string(arguments, "localPath")
        )
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let (client, bucket) = try session()
        let progress = ProgressClosure { [weak self] _, transferred, total in
            self?.emitProgress(taskId, "download", transferred, total)
        }
        do {
            _ = try await client.getObjectToFile(GetObjectRequest(
                bucket: bucket,
                key: try OssBridgeContract.string(arguments, "key"),
                progress: progress
            ), targetURL)
        } catch {
            try? FileManager.default.removeItem(at: targetURL)
            throw error
        }
    }

    private func getObjectBytes(_ arguments: [String: Any]) async throws -> Data {
        NSLog("PDD OSS getObjectBytes configured=\(client != nil && bucket != nil)")
        let maxBytes = (arguments["maxBytes"] as? NSNumber)?.int64Value ?? 0
        guard maxBytes > 0 && maxBytes <= Int64(Int.max) else {
            throw OssBridgeContract.BridgeError.invalidMaxBytes
        }
        let (client, bucket) = try session()
        guard let key = arguments["key"] as? String, !key.isEmpty else {
            throw OssBridgeContract.BridgeError.invalidObjectKey
        }
        var request = GetObjectRequest(
            bucket: bucket,
            key: key,
            range: arguments["range"] as? String
        )
        if let process = arguments["process"] as? String, !process.isEmpty {
            request.addParameter("x-oss-process", process)
        }
        let response = try await client.getObject(request)
        if let length = response.contentLength, length > maxBytes {
            throw OssBridgeContract.BridgeError.contentTooLarge
        }
        let data: Data
        switch response.body {
        case let .data(value): data = value
        case let .file(url): data = try Data(contentsOf: url, options: .mappedIfSafe)
        case let .stream(stream):
            stream.open()
            defer { stream.close() }
            var output = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16 * 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 16 * 1024)
                if count < 0 {
                    throw stream.streamError ?? OssBridgeContract.BridgeError.unknown
                }
                if count == 0 { break }
                if Int64(output.count + count) > maxBytes {
                    throw OssBridgeContract.BridgeError.contentTooLarge
                }
                output.append(buffer, count: count)
            }
            data = output
        default: data = Data()
        }
        guard Int64(data.count) <= maxBytes else {
            throw OssBridgeContract.BridgeError.contentTooLarge
        }
        return data
    }

    private func startTransfer(
        _ arguments: [String: Any],
        result: @escaping FlutterResult,
        operation: @escaping ([String: Any]) async throws -> Void
    ) {
        do {
            let taskId = try OssBridgeContract.string(arguments, "taskId")
            transfers[taskId]?.cancel()
            let task = Task { [weak self] in
                do {
                    try await operation(arguments)
                    try Task.checkCancellation()
                    await MainActor.run { result(nil) }
                } catch {
                    await MainActor.run { result(Self.flutterError(error)) }
                }
                await MainActor.run { self?.transfers.removeValue(forKey: taskId) }
            }
            transfers[taskId] = task
        } catch {
            result(Self.flutterError(error))
        }
    }

    private func perform(
        _ result: @escaping FlutterResult,
        operation: @escaping () async throws -> Any?
    ) {
        Task {
            do {
                let value = try await operation()
                await MainActor.run { result(value) }
            } catch {
                await MainActor.run { result(Self.flutterError(error)) }
            }
        }
    }

    private func session() throws -> (Client, String) {
        guard let client, let bucket else {
            throw OssBridgeContract.BridgeError.notConfigured
        }
        return (client, bucket)
    }

    private func emitProgress(_ taskId: String, _ direction: String, _ transferred: Int64, _ total: Int64) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(OssBridgeContract.progressEvent(
                taskId: taskId,
                direction: direction,
                transferred: transferred,
                total: total
            ))
        }
    }

    static func flutterError(_ error: Error) -> FlutterError {
        let stable = OssBridgeContract.stableError(error)
        return FlutterError(
            code: stable.code,
            message: stable.message,
            details: stable.details
        )
    }
}
