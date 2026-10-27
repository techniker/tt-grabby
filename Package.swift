// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Grabby",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Grabby", targets: ["Grabby"]),
        .executable(name: "grabby-probe", targets: ["grabby-probe"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(
            name: "CGrabby",
            dependencies: ["CLibUSB"],
            cSettings: [.unsafeFlags(["-Wall", "-Wextra"])]
        ),
        .executableTarget(
            name: "grabby-probe",
            dependencies: ["CGrabby"]
        ),
        .executableTarget(
            name: "Grabby",
            dependencies: ["CGrabby"]
        ),
    ]
)
