import Foundation

/// Lance les programmes officiels (claude, agy) pour relever les quotas.
enum Lanceur {
    /// Sortie du programme, remplie depuis deux fils (lecture au fil de l'eau, puis fin).
    private final class Tampon: @unchecked Sendable {
        private let verrou = NSLock()
        private var donnees = Data()

        func ajouter(_ morceau: Data) { verrou.lock(); donnees.append(morceau); verrou.unlock() }

        var contenu: Data { verrou.lock(); defer { verrou.unlock() }; return donnees }
    }

    enum Erreur: LocalizedError {
        case reponse(String)
        var errorDescription: String? {
            switch self {
            case .reponse(let m): m
            }
        }
    }

    /// Lance un programme et renvoie sa sortie standard (l'arrête au bout de `delai` s).
    /// `cheminEnTete` passe devant le PATH (garde du navigateur d'Antigravity).
    static func executer(_ programme: String, _ arguments: [String], dossier: URL, delai: TimeInterval,
                         cheminEnTete: String? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { suite in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: programme)
            p.arguments = arguments
            p.currentDirectoryURL = dossier
            // Une app lancée depuis le Finder n'a pas le PATH du Terminal : claude a besoin de node,
            // souvent rangé à côté de lui (Homebrew, nvm…).
            var env = ProcessInfo.processInfo.environment
            let dossierProgramme = URL(fileURLWithPath: programme).deletingLastPathComponent().path
            env["PATH"] = (cheminEnTete.map { $0 + ":" } ?? "")
                + "\(dossierProgramme):/opt/homebrew/bin:/usr/local/bin:\(Chemins.maison.path)/.local/bin:"
                + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            p.environment = env
            let tuyau = Pipe()
            p.standardOutput = tuyau
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            let tampon = Tampon()
            tuyau.fileHandleForReading.readabilityHandler = { h in
                let morceau = h.availableData
                if morceau.isEmpty { h.readabilityHandler = nil } else { tampon.ajouter(morceau) }
            }
            p.terminationHandler = { _ in
                tuyau.fileHandleForReading.readabilityHandler = nil
                tampon.ajouter(tuyau.fileHandleForReading.readDataToEndOfFile())
                suite.resume(returning: tampon.contenu)
            }
            do { try p.run() } catch { suite.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + delai) { if p.isRunning { p.terminate() } }
        }
    }
}
