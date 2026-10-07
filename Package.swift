// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swift-exif-writer",
    // The oldest systems with the throwing `FileHandle` calls the file edit
    // is built on.
    platforms: [.macOS(.v11), .iOS(.v14), .tvOS(.v14), .watchOS(.v7)],
    products: [
        .library(name: "ExifWriter", targets: ["ExifWriter"]),
    ],
    targets: [
        .target(name: "ExifWriter"),
        .testTarget(name: "ExifWriterTests", dependencies: ["ExifWriter"]),
    ]
)
