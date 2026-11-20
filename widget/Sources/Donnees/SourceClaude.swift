import Foundation

/// Quota de Claude : la commande officielle `/usage` de Claude Code, qui répond
/// sans appeler le modèle (0 jeton) :
/// `claude -p /usage --output-format stream-json --verbose` → événement « assistant »
/// avec usage_report.rate_limits.limits[] (kind session | weekly_all | weekly_scoped,
/// percent 0–100, resets_at ISO 8601). Ce sont les mêmes chiffres que l'anneau
/// d'usage de l'app de bureau (quota partagé par toutes les surfaces Claude Code).
enum SourceClaude {
    struct Resultat {
        var quota: Quota
        /// Limite hebdomadaire propre à un modèle, si elle existe.
        var semaineModele: (nom: String, fenetre: Fenetre)?
    }

    static func lireQuota() async throws -> Resultat {
        guard let claude = Chemins.programme("claude") else { throw Lanceur.Erreur.reponse(Textes.t("widget.claude_introuvable")) }
        try? FileManager.default.createDirectory(at: Chemins.atelier, withIntermediateDirectories: true)
        // Sans crochets ni historique : ce relevé ne doit ni allumer l'icône de Claude
        // ni laisser de session dans l'historique.
        let sortie = try await Lanceur.executer(
            claude, ["-p", "/usage", "--output-format", "stream-json", "--verbose",
                     "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#],
            dossier: Chemins.atelier, delai: 60)

        var limites: [[String: Any]]?
        for ligne in sortie.split(separator: UInt8(ascii: "\n")) {
            guard let e = try? JSONSerialization.jsonObject(with: Data(ligne)) as? [String: Any],
                  let rapport = e["usage_report"] as? [String: Any],
                  let rl = rapport["rate_limits"] as? [String: Any],
                  let l = rl["limits"] as? [[String: Any]] else { continue }
            limites = l
        }
        guard let limites else {
            let texte = String(data: sortie, encoding: .utf8) ?? ""
            throw Lanceur.Erreur.reponse(texte.contains("login") || texte.contains("auth")
                                             ? Textes.t("widget.claude_deconnecte") : Textes.t("widget.releve_illisible"))
        }

        var resultat = Resultat(quota: Quota())
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for limite in limites {
            guard let kind = limite["kind"] as? String,
                  let pourcent = (limite["percent"] as? NSNumber)?.doubleValue else { continue }
            let texteDate = limite["resets_at"] as? String
            let reinit = texteDate.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            let f = Fenetre(utilise: min(max(pourcent / 100, 0), 1), reinitialisation: pourcent > 0 ? reinit : nil)
            switch kind {
            case "session": resultat.quota.cinqHeures = f
            case "weekly_all": resultat.quota.semaine = f
            case "weekly_scoped":
                let modele = ((limite["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                if resultat.semaineModele.map({ $0.fenetre.utilise < f.utilise }) ?? true {
                    resultat.semaineModele = (modele ?? Textes.t("mcp.q_modele"), f)
                }
            default: break
            }
        }
        return resultat
    }
}
