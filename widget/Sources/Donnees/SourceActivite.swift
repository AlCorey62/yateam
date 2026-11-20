import Foundation

/// Qui travaille en ce moment ?
/// - Chargés de projet : leurs scripts (~/.claude/equipe/codex.sh, antigravity.sh) écrivent
///   etat/codex.json et etat/antigravity.json au début et à la fin de chaque tâche.
/// - Le Mac : le connecteur écrit etat/mac.json (même forme), plus le compte des actions du jour.
/// - Claude : les crochets (hooks) de Claude Code écrivent etat/claude/<session>.json
///   (au travail à chaque demande et à chaque outil, libre à la fin du tour).
enum SourceActivite {
    struct Activite {
        var auTravail = false
        var enAttente = false
        var depuis: Date?
        var tache: String?
        var sessions = 0
    }

    struct BilanMac {
        var actionsDuJour = 0
        var derniere: String?
        var date: Date?
        var reussie = true
    }

    /// Le Mac : actions réussies aujourd'hui et dernière action.
    static func bilanMac() -> BilanMac {
        guard let d = lire(Chemins.etat.appendingPathComponent("mac.json")) else { return BilanMac() }
        var bilan = BilanMac()
        if d["jour"] as? String == jour.string(from: Date()) {
            bilan.actionsDuJour = (d["actions_jour"] as? NSNumber)?.intValue ?? 0
        }
        bilan.derniere = d["derniere"] as? String
        bilan.date = date(d["derniere_horodatage"])
        bilan.reussie = d["derniere_ok"] as? Bool ?? true
        return bilan
    }

    /// Même forme que le connecteur (time.strftime("%Y-%m-%d"), heure locale).
    private static let jour: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Un membre qui signale son activité par etat/<membre>.json (Codex, Antigravity, Mac).
    static func chargeDeProjet(_ membre: Membre) -> Activite {
        let url = Chemins.etat.appendingPathComponent("\(membre.rawValue).json")
        guard let d = lire(url), d["au_travail"] as? Bool == true else { return Activite() }
        let maintenant = Date()
        // Plusieurs tâches peuvent tourner à la fois (« actifs », par pid) : on garde celles dont le
        // processus vit encore et qui ont moins de 2 h (un script tué en route ne prévient pas).
        if let actifs = d["actifs"] as? [String: Any] {
            let vivantes: [(Date, String?)] = actifs.compactMap { cle, valeur in
                guard let pid = Int32(cle), pid > 0, let a = valeur as? [String: Any] else { return nil }
                if kill(pid, 0) != 0 && errno == ESRCH { return nil }
                let debut = date(a["debut"]) ?? .distantPast
                guard maintenant.timeIntervalSince(debut) < 2 * 3600 else { return nil }
                return (debut, a["tache"] as? String)
            }
            guard let recente = vivantes.max(by: { $0.0 < $1.0 }) else { return Activite() }
            return Activite(auTravail: true, depuis: recente.0, tache: recente.1, sessions: vivantes.count)
        }
        // Ancien format (un seul pid).
        let horodatage = date(d["horodatage"]) ?? .distantPast
        if let pid = (d["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) != 0, errno == ESRCH {
            return Activite()
        }
        guard maintenant.timeIntervalSince(horodatage) < 2 * 3600 else { return Activite() }
        return Activite(auTravail: true, depuis: horodatage, tache: d["tache"] as? String, sessions: 1)
    }

    /// Claude : toutes ses sessions. Une session est « au travail » si elle a donné
    /// signe de vie depuis moins de 15 min (un tour interrompu ne prévient pas).
    static func claude() -> Activite {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: Chemins.etatClaude, includingPropertiesForKeys: nil) else {
            return Activite()
        }
        var resultat = Activite()
        let maintenant = Date()
        for url in urls where url.pathExtension == "json" {
            guard let d = lire(url) else { continue }
            let horodatage = date(d["horodatage"]) ?? .distantPast
            let age = maintenant.timeIntervalSince(horodatage)
            if age > 24 * 3600 { try? fm.removeItem(at: url); continue }   // vieille session oubliée
            if d["en_attente"] as? Bool == true, age < 3600 { resultat.enAttente = true }
            guard d["au_travail"] as? Bool == true, age < 15 * 60 else { continue }
            resultat.auTravail = true
            resultat.sessions += 1
            if let depuis = date(d["depuis"]), resultat.depuis.map({ depuis < $0 }) ?? true {
                resultat.depuis = depuis
            }
        }
        return resultat
    }

    private static func lire(_ url: URL) -> [String: Any]? {
        guard let donnees = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: donnees)) as? [String: Any]
    }

    private static func date(_ valeur: Any?) -> Date? {
        (valeur as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
}
