import Foundation

/// Les membres de l'équipe : Claude (chef de projet), ses chargés de projet ChatGPT (Codex CLI)
/// et Gemini (Antigravity CLI), et le Mac (Rappels, Calendrier, Notes, Apple Intelligence).
/// Leurs noms (tirés au hasard à l'installation) et leur activation viennent de
/// ~/.claude/equipe/config.json.
enum Membre: String, CaseIterable, Identifiable {
    case claude, codex, antigravity, mac

    var id: String { rawValue }

    var nom: String {
        switch self {
        case .claude: "Claude"
        case .codex, .antigravity, .mac: Reglages.nom(self)
        }
    }

    var role: String {
        switch self {
        case .claude: Textes.t("widget.role_chef")
        case .codex: Textes.t("widget.role_codex")
        case .antigravity: Textes.t("widget.role_antigravity")
        case .mac: Textes.t("widget.role_mac")
        }
    }

    /// Le Mac n'a pas de quota : Rappels, Calendrier et Apple Intelligence tournent sur le Mac.
    var aUnQuota: Bool { self != .mac }

    /// Les membres installés : Claude, plus les membres activés (tous, pour les instantanés de test).
    static var presents: [Membre] {
        #if DEBUG
        if CommandLine.arguments.contains("-YaTeamInstantane") { return allCases }
        #endif
        return allCases.filter { $0 == .claude || Reglages.actif($0) }
    }
}

/// Réglages écrits par install.sh dans ~/.claude/equipe/config.json :
/// { "langue": "fr", "membres": { "codex": { "nom": "Pesto", "actif": true }, "antigravity": { … },
///   "mac": { "nom": "Nougat", "actif": true, "apple_intelligence": true } },
///   "programmes": { "claude": "/chemin/vers/claude", "codex": "…", "agy": "…" } }
enum Reglages {
    private static let defauts: [Membre: String] = [.codex: "Pesto", .antigravity: "Praline", .mac: "Nougat"]

    private static let racine: [String: Any] = {
        guard let donnees = try? Data(contentsOf: Chemins.config),
              let racine = (try? JSONSerialization.jsonObject(with: donnees)) as? [String: Any] else { return [:] }
        return racine
    }()

    private static var lus: [String: [String: Any]] { racine["membres"] as? [String: [String: Any]] ?? [:] }

    static var langue: String? { racine["langue"] as? String }

    /// Chemin d'un programme relevé par install.sh (utile quand il est installé hors des dossiers habituels).
    static func programme(_ nom: String) -> String? {
        (racine["programmes"] as? [String: Any])?[nom] as? String
    }

    static func nom(_ membre: Membre) -> String {
        let brut = (lus[membre.rawValue]?["nom"] as? String)?
            .split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return brut.isEmpty ? defauts[membre] ?? membre.rawValue : String(brut.prefix(30))
    }

    /// Un réglage d'avant la version 2 ne connaît pas le Mac : il reste éteint tant qu'on ne l'a pas choisi.
    static func actif(_ membre: Membre) -> Bool {
        lus[membre.rawValue]?["actif"] as? Bool ?? (membre != .mac)
    }

    /// Apple Intelligence disponible sur ce Mac (relevé à l'installation).
    static var appleIntelligence: Bool { lus["mac"]?["apple_intelligence"] as? Bool ?? false }

}

/// Une fenêtre de quota (5 heures ou semaine).
struct Fenetre: Equatable {
    /// Part consommée, de 0 à 1.
    var utilise: Double
    /// Heure de remise à zéro ; nil quand la fenêtre n'est pas encore entamée.
    var reinitialisation: Date?

    /// La fenêtre telle qu'elle est à l'instant `date` : passée l'heure de remise
    /// à zéro, le compteur repart de 0 même si l'outil ne l'a pas encore réécrit.
    func aLInstant(_ date: Date) -> Fenetre {
        if let r = reinitialisation, r <= date { return Fenetre(utilise: 0, reinitialisation: nil) }
        return self
    }
}

struct Quota: Equatable {
    var cinqHeures: Fenetre?
    var semaine: Fenetre?
}

struct EtatMembre: Equatable {
    var quota = Quota()
    /// Gemini : réserve séparée des modèles tiers d'Antigravity ; Claude : limite propre à un modèle.
    var quotaSecondaire: Quota?
    var libelleSecondaire: String?
    var auTravail = false
    /// Claude : une session attend votre réponse (autorisation, question).
    var enAttente = false
    var depuis: Date?
    var tache: String?
    /// Claude : nombre de sessions en train de travailler.
    var sessionsActives = 0
    /// Date des chiffres de quota affichés.
    var miseAJour: Date?
    /// Message quand la source ne répond pas.
    var probleme: String?
    /// Le Mac : actions réussies aujourd'hui et dernière action (etat/mac.json).
    var actionsDuJour = 0
    var derniereAction: String?
    var derniereActionDate: Date?
    var derniereActionReussie = true
}

enum Chemins {
    static let maison = FileManager.default.homeDirectoryForCurrentUser
    static let equipe = maison.appendingPathComponent(".claude/equipe")
    static let config = equipe.appendingPathComponent("config.json")
    /// Dossier où les chargés de projet et les crochets de Claude signalent leur activité.
    static let etat = equipe.appendingPathComponent("etat")
    static let etatClaude = etat.appendingPathComponent("claude")
    /// Dossier neutre d'où l'on interroge Claude Code et Antigravity.
    static let atelier = equipe.appendingPathComponent("atelier")
    static let sessionsCodex = maison.appendingPathComponent(".codex/sessions")
    /// Garde du navigateur d'Antigravity (faux « open », le même que le connecteur et antigravity.sh).
    static let garde = equipe.appendingPathComponent("garde")
    static let signalNavigateur = garde.appendingPathComponent("navigateur-demande.log")
    /// Copie du kit faite par install.sh (pour « Modifier l'équipe… »).
    static let kit = equipe.appendingPathComponent("kit")
    static let journalMac = etat.appendingPathComponent("journal-mac.txt")

    /// Un programme en ligne de commande : chemin relevé à l'installation, sinon les endroits habituels.
    static func programme(_ nom: String) -> String? {
        let m = maison.path
        let candidats = [Reglages.programme(nom)].compactMap { $0 } + ["/opt/homebrew/bin/\(nom)", "/usr/local/bin/\(nom)", "\(m)/.local/bin/\(nom)",
                         "\(m)/.claude/local/\(nom)", "\(m)/.npm-global/bin/\(nom)"]
        return candidats.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
