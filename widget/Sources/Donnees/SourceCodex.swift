import Foundation

/// Quota du chargé de projet ChatGPT (Codex CLI) : Codex inscrit lui-même ses compteurs
/// (`rate_limits` : primary = 5 h, secondary = semaine) dans son historique
/// ~/.codex/sessions/AAAA/MM/JJ/rollout-*.jsonl, à chaque tâche.
/// Les chiffres bougent donc quand Codex travaille (ce chargé de projet ou une autre utilisation de Codex).
enum SourceCodex {
    static func lireQuota() -> (Quota, Date)? {
        for (url, date) in fichiersRecents().prefix(6) {
            if let quota = dernierQuota(dans: url) { return (quota, date) }
        }
        return nil
    }

    /// Fichiers d'historique des 8 derniers jours, les plus récemment écrits d'abord.
    private static func fichiersRecents() -> [(URL, Date)] {
        let fm = FileManager.default
        let cal = Calendar.current
        var fichiers: [(URL, Date)] = []
        for decalage in 0..<8 {
            guard let jour = cal.date(byAdding: .day, value: -decalage, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: jour)
            let dossier = Chemins.sessionsCodex.appendingPathComponent(
                String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            guard let urls = try? fm.contentsOfDirectory(
                at: dossier, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in urls where url.pathExtension == "jsonl" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                fichiers.append((url, date))
            }
        }
        return fichiers.sorted { $0.1 > $1.1 }
    }

    /// Derniers compteurs du fichier (on ne lit que sa fin).
    private static func dernierQuota(dans url: URL) -> Quota? {
        guard let poignee = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? poignee.close() }
        let taille = (try? poignee.seekToEnd()) ?? 0
        let fin: UInt64 = 512 * 1024
        try? poignee.seek(toOffset: taille > fin ? taille - fin : 0)
        guard let donnees = try? poignee.readToEnd(),
              let texte = String(data: donnees, encoding: .utf8) else { return nil }

        for ligne in texte.split(separator: "\n").reversed() where ligne.contains("\"rate_limits\"") {
            guard let objet = try? JSONSerialization.jsonObject(with: Data(ligne.utf8)),
                  let limites = chercherLimites(objet) else { continue }
            var quota = Quota()
            for cle in ["primary", "secondary"] {
                guard let f = limites[cle] as? [String: Any],
                      let pourcent = (f["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = (f["window_minutes"] as? NSNumber)?.intValue ?? (cle == "primary" ? 300 : 10080)
                let reinit = (f["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                let fenetre = Fenetre(utilise: min(max(pourcent / 100, 0), 1), reinitialisation: reinit)
                if minutes <= 24 * 60 { quota.cinqHeures = fenetre } else { quota.semaine = fenetre }
            }
            if quota.cinqHeures != nil || quota.semaine != nil { return quota }
        }
        return nil
    }

    /// Cherche, n'importe où dans l'événement, l'objet `rate_limits` de Codex.
    private static func chercherLimites(_ objet: Any) -> [String: Any]? {
        if let dico = objet as? [String: Any] {
            if let r = dico["rate_limits"] as? [String: Any], r["primary"] != nil || r["secondary"] != nil {
                if let id = r["limit_id"] as? String, id != "codex" { return nil }
                return r
            }
            for valeur in dico.values { if let r = chercherLimites(valeur) { return r } }
        } else if let liste = objet as? [Any] {
            for valeur in liste { if let r = chercherLimites(valeur) { return r } }
        }
        return nil
    }
}
