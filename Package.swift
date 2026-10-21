// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Xipixiaojuchang",
    platforms: [.macOS("26.0")],   // 🧪 26+ 才有新 UI（红绿灯玻璃质感）；低于它走旧渲染（平涂灰点）
    targets: [
        .systemLibrary(
            name: "CCommonCrypto",
            path: "Sources/CCommonCrypto"
        ),
        .executableTarget(
            name: "Xipixiaojuchang",
            dependencies: ["CCommonCrypto"],
            path: "Sources/Xipixiaojuchang",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "XipixiaojuchangTests",
            dependencies: ["Xipixiaojuchang"],
            path: "Tests/XipixiaojuchangTests"
        )
    ]
)
