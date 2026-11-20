// swift-tools-version:5.9
// Widget « YaTeam » : se construit avec les seuls outils de ligne de commande d'Apple
// (xcode-select --install), sans l'app Xcode. Voir outils/construire.sh.
import PackageDescription

let package = Package(
    name: "YaTeam",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "YaTeam",
            path: "Sources",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
    ]
)
