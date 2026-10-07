// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swift-exif-writer",
    products: [
        .library(name: "ExifWriter", targets: ["ExifWriter"]),
    ],
    targets: [
        .target(name: "ExifWriter"),
        .testTarget(name: "ExifWriterTests", dependencies: ["ExifWriter"]),
    ]
)
