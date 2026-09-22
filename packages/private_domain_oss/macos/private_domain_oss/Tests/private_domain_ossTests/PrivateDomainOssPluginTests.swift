import AlibabaCloudOSS
import XCTest
@testable import private_domain_oss_contract

final class PrivateDomainOssPluginTests: XCTestCase {
    func testSessionReadsDocumentedOssFields() throws {
        let values = try OssBridgeContract.session([
            "endpoint": "https://oss-cn-hangzhou.aliyuncs.com",
            "region": "cn-hangzhou",
            "bucket": "test-bucket",
            "accessKeyId": "client-id",
            "accessKeySecret": "client-secret",
        ])

        XCTAssertEqual(values.endpoint, "https://oss-cn-hangzhou.aliyuncs.com")
        XCTAssertEqual(values.region, "cn-hangzhou")
        XCTAssertEqual(values.bucket, "test-bucket")
        XCTAssertEqual(values.accessKeyId, "client-id")
        XCTAssertEqual(values.accessKeySecret, "client-secret")
    }

    func testSessionRejectsMissingFields() {
        XCTAssertThrowsError(try OssBridgeContract.session([:])) { error in
            XCTAssertTrue(error is OssBridgeContract.BridgeError)
        }
        XCTAssertThrowsError(try OssBridgeContract.string(["bucket": ""], "bucket"))
    }

    func testListResultMapsSdkModelsToPlatformValues() throws {
        let value = OssBridgeContract.listResult(
            objects: [OssBridgeContract.ObjectValues(
            key: "shared/a.txt",
            size: 12,
            lastModified: Date(timeIntervalSince1970: 123),
            etag: "etag-a",
            storageClass: "Standard"
            )],
            commonPrefixes: ["shared/folder/"],
            isTruncated: true,
            nextMarker: "next-token"
        )
        let objects = try XCTUnwrap(value["objects"] as? [[String: Any]])
        XCTAssertEqual(objects.first?["key"] as? String, "shared/a.txt")
        XCTAssertEqual(objects.first?["size"] as? Int, 12)
        XCTAssertEqual(objects.first?["lastModifiedMilliseconds"] as? Int64, 123_000)
        XCTAssertEqual(objects.first?["etag"] as? String, "etag-a")
        XCTAssertEqual(objects.first?["storageClass"] as? String, "Standard")
        XCTAssertEqual(value["commonPrefixes"] as? [String], ["shared/folder/"])
        XCTAssertEqual(value["isTruncated"] as? Bool, true)
        XCTAssertEqual(value["nextMarker"] as? String, "next-token")
    }

    func testProgressEventUsesStableFieldsAndClampsNegativeValues() {
        let value = OssBridgeContract.progressEvent(
            taskId: "upload-1",
            direction: "upload",
            transferred: -1,
            total: -1
        )

        XCTAssertEqual(value["taskId"] as? String, "upload-1")
        XCTAssertEqual(value["direction"] as? String, "upload")
        XCTAssertEqual(value["transferredBytes"] as? Int64, 0)
        XCTAssertEqual(value["totalBytes"] as? Int64, 0)
    }

    func testCancellationAndClientErrorsUseStableSanitizedCodes() {
        let canceled = OssBridgeContract.stableError(CancellationError())
        XCTAssertEqual(canceled.code, "canceled")

        let secret = "temporary-secret"
        let token = "temporary-token"
        let network = OssBridgeContract.stableError(ClientError(
            code: "RequestError",
            message: "\(secret) \(token)"
        ))
        XCTAssertEqual(network.code, "networkUnavailable")
        XCTAssertFalse(network.message.contains(secret))
        XCTAssertFalse(network.message.contains(token))
        XCTAssertEqual(network.details?["sdkCode"] as? String, "RequestError")

        let invalid = OssBridgeContract.stableError(ClientError(
            code: "ParameterError",
            message: "invalid"
        ))
        XCTAssertEqual(invalid.code, "invalidRequest")
        XCTAssertEqual(invalid.details?["sdkCode"] as? String, "ParameterError")
    }

    func testBridgeErrorsUseStableCodesWithoutSensitiveDetails() {
        let tooLarge = OssBridgeContract.stableError(
            OssBridgeContract.BridgeError.contentTooLarge
        )
        XCTAssertEqual(tooLarge.code, "invalidRequest")
        XCTAssertEqual(tooLarge.details?["bridgeCode"] as? String, "contentTooLarge")

        let notConfigured = OssBridgeContract.stableError(
            OssBridgeContract.BridgeError.notConfigured
        )
        XCTAssertEqual(notConfigured.code, "invalidRequest")
        XCTAssertEqual(notConfigured.details?["bridgeCode"] as? String, "notConfigured")
    }
}
