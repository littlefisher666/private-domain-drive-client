// swift-tools-version: 5.10

import PackageDescription
import Foundation

// FlutterMacOS 只在 Flutter/Xcode 构建环境中可用。纯 Swift 契约测试通过
// PRIVATE_DOMAIN_OSS_CONTRACT_TESTS=1 排除插件目标，直接验证桥接数据契约。
let contractTestsOnly = ProcessInfo.processInfo.environment[
    "PRIVATE_DOMAIN_OSS_CONTRACT_TESTS"
] == "1"

var products: [Product] = []
var dependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2.git",
        exact: "0.4.0"
    )
]
var targets: [Target] = [
    .target(
        name: "private_domain_oss_contract",
        dependencies: [
            .product(
                name: "AlibabaCloudOSS",
                package: "alibabacloud-oss-swift-sdk-v2"
            )
        ]
    ),
    .testTarget(
        name: "private_domain_ossTests",
        dependencies: [
            "private_domain_oss_contract",
            .product(
                name: "AlibabaCloudOSS",
                package: "alibabacloud-oss-swift-sdk-v2"
            )
        ]
    )
]

if !contractTestsOnly {
    products.append(
        .library(name: "private-domain-oss", targets: ["private_domain_oss"])
    )
    dependencies.insert(
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        at: 0
    )
    targets.insert(
        .target(
            name: "private_domain_oss",
            dependencies: [
                "private_domain_oss_contract",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(
                    name: "AlibabaCloudOSS",
                    package: "alibabacloud-oss-swift-sdk-v2"
                )
            ]
        ),
        at: 0
    )
}

let package = Package(
    name: "private_domain_oss",
    platforms: [.macOS(.v12)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
