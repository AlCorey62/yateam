import AppKit
import UserNotifications

/// Préférences du panneau, gardées d'un lancement à l'autre (les membres, leurs noms et la langue
/// viennent de config.json, voir Reglages).
@MainActor
final class Preferences: ObservableObject {
    static let partage = Preferences()
    private let d = UserDefaults.standard

    /// Membres dont la carte est masquée dans le panneau et le menu.
    @Published var membresMasques: Set<Membre> {
        didSet { d.set(membresMasques.map(\.rawValue), forKey: "membresMasques") }
    }
    /// Minutes entre deux relevés automatiques (Claude, Gemini).
    @Published var intervalleClaude: Int { didSet { d.set(intervalleClaude, forKey: "intervalleClaude") } }
    @Published var intervalleAntigravity: Int { didSet { d.set(intervalleAntigravity, forKey: "intervalleAntigravity") } }
    /// Notification quand un quota dépasse ce pourcentage ; 0 = jamais.
    @Published var seuilAlerte: Int { didSet { d.set(seuilAlerte, forKey: "seuilAlerte") } }
    /// Panneau posé sur le bureau, derrière les fenêtres (par défaut), ou flottant au-dessus d'elles.
    @Published var panneauSurBureau: Bool { didSet { d.set(panneauSurBureau, forKey: "panneauSurBureau") } }

    private init() {
        membresMasques = Set((d.stringArray(forKey: "membresMasques") ?? []).compactMap(Membre.init(rawValue:)))
        intervalleClaude = d.object(forKey: "intervalleClaude") as? Int ?? 15
        intervalleAntigravity = d.object(forKey: "intervalleAntigravity") as? Int ?? 15
        seuilAlerte = d.object(forKey: "seuilAlerte") as? Int ?? 0
        panneauSurBureau = d.object(forKey: "panneauSurBureau") as? Bool ?? true
    }

    /// Les membres installés dont la carte n'est pas masquée (au moins un).
    var membresAffiches: [Membre] {
        let affiches = Membre.presents.filter { !membresMasques.contains($0) }
        return affiches.isEmpty ? Membre.presents : affiches
    }

    func intervalle(_ membre: Membre) -> TimeInterval {
        TimeInterval(membre == .antigravity ? intervalleAntigravity : intervalleClaude) * 60
    }
}

/// Notifications de quota (« Praline : 90 % de la semaine utilisés »).
enum Alertes {
    static func demanderAutorisation() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Vrai si la notification est partie (notifications autorisées et ajout réussi).
    static func envoyer(titre: String, corps: String) async -> Bool {
        let centre = UNUserNotificationCenter.current()
        let statut = await centre.notificationSettings().authorizationStatus
        guard statut == .authorized || statut == .provisional else { return false }
        let contenu = UNMutableNotificationContent()
        contenu.title = titre
        contenu.body = corps
        contenu.sound = .default
        do {
            try await centre.add(UNNotificationRequest(identifier: UUID().uuidString, content: contenu, trigger: nil))
            return true
        } catch {
            return false
        }
    }
}

/// Ouvre le Terminal sur un petit script : un fichier .command, que le Terminal exécute à
/// l'ouverture (aucune autorisation « Automatisation » à donner).
enum Terminal {
    /// Chemin protégé pour le shell : entre apostrophes, les apostrophes du chemin échappées.
    static func q(_ texte: String) -> String {
        "'" + texte.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func ouvrir(_ nom: String, script: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("YaTeam - \(nom).command")
        try ("#!/bin/zsh\nclear\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    /// Une ligne affichée par le script (texte protégé).
    static func echo(_ texte: String) -> String { "print -r -- " + q(texte) }
}

/// « Reconnecter… » : ouvre le Terminal sur la commande de connexion officielle du membre,
/// avec les explications dans la langue choisie.
enum Reconnexion {
    static func lancer(_ membre: Membre) throws {
        let fin = Terminal.echo("") + "\n" + Terminal.echo(Textes.t("widget.reco_fin"))
        let script: String
        switch membre {
        case .claude:
            let claude = Chemins.programme("claude") ?? "claude"
            script = [Terminal.echo(Textes.t("widget.reco_titre", ["nom": "Claude Code"])), Terminal.echo(""),
                      Terminal.echo(Textes.t("widget.reco_navigateur")), Terminal.echo(""),
                      "\(Terminal.q(claude)) auth login", fin].joined(separator: "\n")
        case .codex:
            let codex = Chemins.programme("codex") ?? "codex"
            script = [Terminal.echo(Textes.t("widget.reco_titre", ["nom": "\(membre.nom) (Codex, ChatGPT)"])),
                      Terminal.echo(""), Terminal.echo(Textes.t("widget.reco_navigateur")), Terminal.echo(""),
                      "\(Terminal.q(codex)) login", fin].joined(separator: "\n")
        case .antigravity:
            let agy = Chemins.programme("agy") ?? "agy"
            script = [Terminal.echo(Textes.t("widget.reco_titre", ["nom": "\(membre.nom) (Antigravity, Google)"])),
                      Terminal.echo(""), Terminal.echo(Textes.t("widget.reco_agy_1")),
                      Terminal.echo(Textes.t("widget.reco_agy_2")), Terminal.echo(""),
                      "mkdir -p \(Terminal.q(Chemins.atelier.path)) && cd \(Terminal.q(Chemins.atelier.path)) && \(Terminal.q(agy))",
                      fin].joined(separator: "\n")
        case .mac:
            return
        }
        try Terminal.ouvrir(Textes.t("widget.reconnecter_titre", ["nom": membre.nom]), script: script)
    }
}

/// « Modifier l'équipe… » : relance l'installation (questions dans des fenêtres) depuis la copie
/// du kit faite par install.sh : ajouter ou retirer une IA, changer la langue ou les surnoms.
enum ModifierEquipe {
    static var disponible: Bool {
        FileManager.default.isExecutableFile(atPath: Chemins.kit.appendingPathComponent("install.sh").path)
    }

    static func lancer() throws {
        let kit = Terminal.q(Chemins.kit.path)
        try Terminal.ouvrir(Textes.t("widget.modifier_equipe_titre"),
                            script: "cd \(kit) && ./install.sh --fenetres")
    }
}
