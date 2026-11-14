// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Actualizate",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CPty", path: "Sources/CPty"),
        .target(name: "RaizComun", path: "Sources/RaizComun"),
        .executableTarget(name: "Actualizate", dependencies: ["CPty", "RaizComun"], path: "Sources/Actualizate"),
        // Ayudante root (LaunchDaemon dentro de la app) para actualizar sin contrasena
        .executableTarget(name: "ActualizateRaiz", dependencies: ["RaizComun"], path: "Sources/ActualizateRaiz"),
    ]
)
