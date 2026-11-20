#if DEBUG
import SwiftUI

/// Instantanés de contrôle (version de test uniquement), sans fenêtre à l'écran
/// ni autorisation d'enregistrement : l'app dessine ses vues dans des PNG puis se ferme.
///   -YaTeamInstantane <dossier>          données de démonstration (libres / au travail)
///   -YaTeamInstantane <dossier> -reel    vraies données, relevées pendant 15 s
@MainActor
enum Instantane {
    static var dossier: URL? { argument("-YaTeamInstantane").map { URL(fileURLWithPath: $0) } }

    /// Valeur d'une option de la ligne de commande (« -Option valeur »).
    nonisolated static func argument(_ option: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: option), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static var demande: Bool { dossier != nil }
    static var reel: Bool { CommandLine.arguments.contains("-reel") }

    static func produire(surveillance: Surveillance, delegue: Delegue) {
        guard let dossier else { return }
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        if reel {
            Task {
                try? await Task.sleep(for: .seconds(15))
                ecrire(ContenuPanneau(etats: surveillance.etats, maintenant: Date(), tempsFige: 0.4, fond: .uni),
                       dossier.appendingPathComponent("reel.png"))
                NSApp.terminate(nil)
            }
            return
        }
        // -YaTeamToutesLangues : le panneau et les personnages dans chaque langue (captures du README).
        if CommandLine.arguments.contains("-YaTeamToutesLangues") {
            for langue in Textes.langues {
                Textes.choisir(langue)
                let etats = etatsDemo()
                ecrire(ContenuPanneau(etats: etats, maintenant: Date(), tempsFige: 0.4, fond: .uni),
                       dossier.appendingPathComponent("panneau-\(langue).png"))
                ecrire(portraits, dossier.appendingPathComponent("portraits-\(langue).png"))
            }
            NSApp.terminate(nil)
            return
        }
        let maintenant = Date()
        var libres = etatsDemo()
        for m in Membre.allCases { libres[m]?.auTravail = false; libres[m]?.tache = nil }
        ecrire(ContenuPanneau(etats: libres, maintenant: maintenant, tempsFige: 0, fond: .uni),
               dossier.appendingPathComponent("libres.png"))
        for (i, t) in [0.0, 0.4, 0.8].enumerated() {
            ecrire(ContenuPanneau(etats: etatsDemo(), maintenant: maintenant, tempsFige: t, fond: .uni),
                   dossier.appendingPathComponent("travail-\(i).png"))
        }
        // Planche des icônes : chaque membre, au repos puis 8 images de son animation.
        let planche = VStack(spacing: 10) {
            ForEach(Membre.allCases) { m in
                HStack(spacing: 10) {
                    IconeMembre(membre: m, auTravail: false, tempsFige: 0).frame(width: 80, height: 62)
                    ForEach(0..<8) { k in
                        IconeMembre(membre: m, auTravail: true, tempsFige: Double(k) * 0.18).frame(width: 80, height: 62)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.11))
        ecrire(planche, dossier.appendingPathComponent("icones.png"))
        ecrire(portraits, dossier.appendingPathComponent("portraits.png"))
        NSApp.terminate(nil)
    }

    /// Les quatre personnages en grand, au travail, avec leur nom et leur rôle.
    private static var portraits: some View {
        HStack(spacing: 24) {
            ForEach(Membre.allCases) { m in
                VStack(spacing: 6) {
                    IconeDessin(membre: m, actif: true, t: 0.3).frame(width: 174, height: 138)
                    Text(m.nom).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(m.role).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.11)))
    }

    private static func ecrire(_ vue: some View, _ url: URL) {
        let rendu = ImageRenderer(content: vue)
        rendu.scale = 2
        guard let image = rendu.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    static func etatsDemo() -> [Membre: EtatMembre] {
        let maintenant = Date()
        var claude = EtatMembre()
        claude.quota = Quota(cinqHeures: Fenetre(utilise: 0.42, reinitialisation: maintenant + 72 * 60),
                             semaine: Fenetre(utilise: 0.29, reinitialisation: maintenant + 2 * 86400 + 3600))
        claude.auTravail = true
        claude.depuis = maintenant - 4 * 60
        claude.sessionsActives = 2
        claude.miseAJour = maintenant - 60

        var codex = EtatMembre()
        codex.quota = Quota(cinqHeures: Fenetre(utilise: 0.67, reinitialisation: maintenant + 3 * 3600),
                            semaine: Fenetre(utilise: 0.12, reinitialisation: maintenant + 6 * 86400))
        codex.miseAJour = maintenant - 25 * 60

        var antigravity = EtatMembre()
        antigravity.quota = Quota(cinqHeures: Fenetre(utilise: 0.91, reinitialisation: maintenant + 20 * 60),
                                  semaine: Fenetre(utilise: 0.07, reinitialisation: maintenant + 5 * 86400))
        antigravity.quotaSecondaire = Quota(cinqHeures: Fenetre(utilise: 0, reinitialisation: nil),
                                            semaine: Fenetre(utilise: 0.02, reinitialisation: maintenant + 5 * 86400))
        antigravity.libelleSecondaire = Textes.t("widget.tiers", ["nom": Membre.antigravity.nom])
        antigravity.auTravail = true
        antigravity.depuis = maintenant - 50
        antigravity.tache = Textes.t("widget.demo_tache")
        antigravity.miseAJour = maintenant - 2 * 60

        var mac = EtatMembre()
        mac.actionsDuJour = 3
        mac.derniereAction = Textes.t("widget.demo_action_mac")
        mac.derniereActionDate = maintenant - 12 * 60
        return [.claude: claude, .codex: codex, .antigravity: antigravity, .mac: mac]
    }
}
#endif
