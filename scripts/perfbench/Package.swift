// swift-tools-version:5.10
import PackageDescription

// Clipora 查询性能基准：复刻 DatabaseManager 的 schema 与 SQL，
// 灌入可复现的模拟数据后测量唤起/搜索/写入/清理耗时。
// GRDB 直接复用主工程已解析的 checkout，保证与 App 同版本（v7.11.1）、零网络。
let package = Package(
    name: "perfbench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../build/SourcePackages/checkouts/GRDB.swift"),
    ],
    targets: [
        .executableTarget(
            name: "perfbench",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
