import Foundation

/// Quota du chargé de projet Gemini : la commande officielle `/quota` d'Antigravity CLI,
/// qui répond tout de suite et ne consomme rien :
/// `agy -p /quota --output-format json` → command.data.groups[].buckets[]
/// (window "5h" | "weekly", remaining_fraction, reset_time).
/// Les réserves « 3p-… » sont celles des modèles tiers proposés par Antigravity.
///
/// Garde du navigateur : quand la connexion Google est à refaire, agy lance « open <page de
/// connexion> » ; sans garde, chaque relevé automatique ouvrirait une page. agy tourne donc avec
/// un faux « open » en tête du PATH (le même, à l'octet près, que le connecteur et antigravity.sh),
/// qui note la demande au lieu d'ouvrir une page. Le relevé échoue alors avec `.reconnexion`, et la
/// surveillance met les relevés en pause jusqu'à « Actualiser ».
enum SourceAntigravity {
    struct Resultat {
        var gemini: Quota
        var tiers: Quota?
    }

    enum Erreur: LocalizedError {
        case reconnexion
        var errorDescription: String? {
            Textes.t("widget.agy_reconnexion", ["nom": Membre.antigravity.nom])
        }
    }

    static func lireQuota() async throws -> Resultat {
        guard let agy = Chemins.programme("agy") else { throw Lanceur.Erreur.reponse(Textes.t("widget.agy_introuvable")) }
        try? FileManager.default.createDirectory(at: Chemins.atelier, withIntermediateDirectories: true)
        guard let garde = preparerGarde() else { throw Lanceur.Erreur.reponse(Textes.t("widget.garde_impossible")) }
        let debut = Date()
        let sortie: Data
        do {
            sortie = try await Lanceur.executer(agy, ["-p", "/quota", "--output-format", "json", "--print-timeout", "60s"],
                                                dossier: Chemins.atelier, delai: 90, cheminEnTete: garde.path)
        } catch {
            if demandeNavigateur(depuis: debut) { throw Erreur.reconnexion }
            throw error
        }
        // Antigravity a voulu ouvrir le navigateur : sa connexion Google est à refaire.
        if demandeNavigateur(depuis: debut) { throw Erreur.reconnexion }
        guard let racine = try? JSONSerialization.jsonObject(with: sortie) as? [String: Any],
              let commande = racine["command"] as? [String: Any],
              let data = commande["data"] as? [String: Any],
              let groupes = data["groups"] as? [[String: Any]] else {
            let texte = String(data: sortie, encoding: .utf8)?.prefix(300).lowercased() ?? ""
            if texte.contains("authentication") || texte.contains("log in") || texte.contains("login") { throw Erreur.reconnexion }
            throw Lanceur.Erreur.reponse(texte.contains("logged") ? Textes.t("widget.agy_deconnecte") : Textes.t("widget.releve_illisible"))
        }

        var gemini: [String: Fenetre] = [:]
        var tiers: [String: Fenetre] = [:]
        for groupe in groupes {
            for seau in groupe["buckets"] as? [[String: Any]] ?? [] {
                guard let id = seau["id"] as? String,
                      let fenetre = seau["window"] as? String,
                      let reste = (seau["remaining_fraction"] as? NSNumber)?.doubleValue else { continue }
                let reinit = (seau["reset_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                // Fenêtre pleine : Antigravity annonce « maintenant + durée », elle n'a pas commencé.
                let f = Fenetre(utilise: min(max(1 - reste, 0), 1), reinitialisation: reste >= 0.9999 ? nil : reinit)
                // On garde, par fenêtre, la réserve la plus entamée (la limite qui bloquera en premier).
                if id.hasPrefix("3p") {
                    if tiers[fenetre].map({ $0.utilise < f.utilise }) ?? true { tiers[fenetre] = f }
                } else {
                    if gemini[fenetre].map({ $0.utilise < f.utilise }) ?? true { gemini[fenetre] = f }
                }
            }
        }
        let quotaTiers = Quota(cinqHeures: tiers["5h"], semaine: tiers["weekly"])
        return Resultat(gemini: Quota(cinqHeures: gemini["5h"], semaine: gemini["weekly"]),
                        tiers: tiers.isEmpty ? nil : quotaTiers)
    }

    /// Le faux « open » a-t-il été appelé depuis `debut` ? (date du fichier de signal, jamais effacé :
    /// le connecteur et antigravity.sh le lisent aussi.)
    static func demandeNavigateur(depuis debut: Date) -> Bool {
        guard let attributs = try? FileManager.default.attributesOfItem(atPath: Chemins.signalNavigateur.path),
              let date = attributs[.modificationDate] as? Date else { return false }
        return date >= debut
    }

    /// Crée (ou remet d'aplomb) les faux « open » et « xdg-open ». nil si c'est impossible : on ne
    /// lance alors pas agy.
    static func preparerGarde() -> URL? {
        // Le chemin est écrit entre guillemets dans le script : un caractère qui les casserait
        // (impossible dans un nom de compte macOS, mais on ne prend aucun risque) annule la garde.
        guard !Chemins.signalNavigateur.path.contains(where: { "\"$`\\".contains($0) }) else { return nil }
        let dossier = Chemins.garde.appendingPathComponent("bin")
        let fm = FileManager.default
        let script = """
        #!/bin/sh
        # YaTeam: an automatic check never opens the browser.
        echo "$(date '+%Y-%m-%d %H:%M:%S') open request blocked" >> "\(Chemins.signalNavigateur.path)"
        exit 0

        """
        do {
            try fm.createDirectory(at: dossier, withIntermediateDirectories: true)
            for nom in ["open", "xdg-open"] {
                let url = dossier.appendingPathComponent(nom)
                if (try? String(contentsOf: url, encoding: .utf8)) != script {
                    try script.write(to: url, atomically: true, encoding: .utf8)
                }
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            return dossier
        } catch {
            return nil
        }
    }
}
