import SwiftUI

/// Fenêtre « Réglages de YaTeam », ouverte depuis le menu ou le clic droit sur le panneau.
/// Fenêtre maison plutôt qu'une scène Settings : une app de barre des menus ne peut pas
/// ouvrir celle-ci depuis le panneau. (Lignes en LabeledContent dans un Form groupé : des
/// HStack avec Spacer et largeur fixe y font planter AppKit sur certaines versions de macOS.)
@MainActor
enum FenetreReglages {
    private static var fenetre: NSWindow?

    static func montrer(surveillance: Surveillance, delegue: Delegue) {
        if fenetre == nil {
            let hote = NSHostingController(rootView: VueReglages(surveillance: surveillance, delegue: delegue))
            let f = NSWindow(contentViewController: hote)
            f.title = Textes.t("widget.reglages_titre")
            f.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            f.setContentSize(NSSize(width: 520, height: 720))
            f.isReleasedWhenClosed = false
            f.center()
            fenetre = f
        }
        NSApp.activate(ignoringOtherApps: true)
        fenetre?.makeKeyAndOrderFront(nil)
    }
}

struct VueReglages: View {
    @ObservedObject var surveillance: Surveillance
    @ObservedObject var delegue: Delegue
    @ObservedObject private var preferences = Preferences.partage
    @State private var erreur: String?

    private var presents: [Membre] { Membre.presents }

    var body: some View {
        Form {
            Section {
                ForEach(presents.filter(\.aUnQuota)) { m in
                    LabeledContent {
                        Button(Textes.t("widget.reconnecter")) { reconnecter(m) }
                    } label: {
                        Text(m.nom)
                        Text(etatConnexion(m)).foregroundStyle(enDifficulte(m) ? Color.orange : Color.secondary)
                    }
                }
                if let erreur {
                    Text(erreur).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text(Textes.t("widget.connexions"))
            } footer: {
                Text(Textes.t("widget.connexions_aide")).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button(Textes.t("widget.modifier_equipe")) { modifierEquipe() }
                        .disabled(!ModifierEquipe.disponible)
                } label: {
                    Text(Textes.t("widget.membres_installes"))
                    Text(presents.filter { $0 != .claude }.map { "\($0.nom) (\(ia($0)))" }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(Textes.t("widget.equipe"))
            } footer: {
                Text(Textes.t(ModifierEquipe.disponible ? "widget.modifier_equipe_aide" : "widget.kit_absent"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if presents.contains(.mac) {
                Section {
                    LabeledContent(Textes.t("widget.apple_intelligence")) {
                        Text(Textes.t(Reglages.appleIntelligence ? "widget.disponible" : "widget.indisponible"))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(Textes.t("widget.ouvrir")) {
                        HStack {
                            Button(Textes.t("widget.journal")) { ouvrirJournal() }
                            Button(Textes.t("widget.autorisations")) {
                                ouvrir(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"))
                            }
                        }
                    }
                } header: {
                    Text(Membre.mac.nom + " · " + Textes.t("widget.role_mac"))
                } footer: {
                    Text(Textes.t("widget.mac_aide")).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(Textes.t("widget.affichage")) {
                ForEach(presents) { m in
                    Toggle(Textes.t("widget.carte_de", ["nom": m.nom]), isOn: visible(m))
                        .disabled(preferences.membresAffiches == [m])
                }
                Toggle(Textes.t("widget.afficher_panneau"), isOn: $delegue.panneauVisible)
                Picker(Textes.t("widget.place_panneau"), selection: $preferences.panneauSurBureau) {
                    Text(Textes.t("widget.place_bureau")).tag(true)
                    Text(Textes.t("widget.place_flottant")).tag(false)
                }
                LabeledContent(Textes.t("widget.position_panneau")) {
                    Button(Textes.t("widget.replacer")) { delegue.replacerPanneau() }
                }
                ToggleOuvertureSession()
            }

            Section {
                Picker("Claude", selection: $preferences.intervalleClaude) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text(Textes.t("widget.toutes_les", ["n": $0])).tag($0) }
                }
                if presents.contains(.antigravity) {
                    Picker(Membre.antigravity.nom, selection: $preferences.intervalleAntigravity) {
                        ForEach([5, 15, 30, 60], id: \.self) { Text(Textes.t("widget.toutes_les", ["n": $0])).tag($0) }
                    }
                }
            } header: {
                Text(Textes.t("widget.releves"))
            } footer: {
                Text(Textes.t("widget.releves_aide")).font(.caption).foregroundStyle(.secondary)
            }

            Section(Textes.t("widget.alertes")) {
                Picker(Textes.t("widget.prevenir"), selection: $preferences.seuilAlerte) {
                    Text(Textes.t("widget.jamais")).tag(0)
                    ForEach([75, 80, 90], id: \.self) { Text(Textes.t("commun.pourcent", ["n": $0])).tag($0) }
                }
                .onChange(of: preferences.seuilAlerte) { _, seuil in
                    if seuil > 0 { Task { _ = await Alertes.demanderAutorisation() } }
                }
                LabeledContent(Textes.t("widget.essai")) {
                    Button(Textes.t("widget.notification_essai")) {
                        Task {
                            if await Alertes.demanderAutorisation(),
                               await Alertes.envoyer(titre: "YaTeam", corps: Textes.t("widget.notification_essai_corps")) {
                                erreur = nil
                            } else {
                                erreur = Textes.t("widget.notifications_refusees")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 720)
    }

    private func ia(_ m: Membre) -> String {
        switch m {
        case .codex: "ChatGPT"
        case .antigravity: "Gemini"
        case .mac: "Mac"
        case .claude: "Claude"
        }
    }

    private func etatConnexion(_ m: Membre) -> String {
        if m == .antigravity && surveillance.antigravityEnPause { return Textes.t("widget.reconnexion_demandee") }
        let e = surveillance.etats[m]
        if let probleme = e?.probleme { return probleme }
        if let maj = e?.miseAJour {
            return Textes.t("widget.connecte_releve", ["quand": Format.anciennete(maj, Date())])
        }
        return Textes.t("widget.pas_de_releve")
    }

    private func enDifficulte(_ m: Membre) -> Bool {
        (m == .antigravity && surveillance.antigravityEnPause) || (m != .codex && surveillance.etats[m]?.probleme != nil)
    }

    private func reconnecter(_ m: Membre) {
        do {
            try Reconnexion.lancer(m)
            surveillance.attendreReconnexion(m)
            erreur = nil
        } catch {
            erreur = Textes.t("widget.terminal_impossible", ["erreur": error.localizedDescription])
        }
    }

    private func modifierEquipe() {
        do {
            try ModifierEquipe.lancer()
            erreur = nil
        } catch {
            erreur = Textes.t("widget.terminal_impossible", ["erreur": error.localizedDescription])
        }
    }

    private func visible(_ m: Membre) -> Binding<Bool> {
        Binding(get: { !preferences.membresMasques.contains(m) },
                set: { if $0 { preferences.membresMasques.remove(m) } else { preferences.membresMasques.insert(m) } })
    }

    private func ouvrirJournal() {
        if !FileManager.default.fileExists(atPath: Chemins.journalMac.path) {
            try? FileManager.default.createDirectory(at: Chemins.etat, withIntermediateDirectories: true)
            try? Data().write(to: Chemins.journalMac)
        }
        ouvrir(Chemins.journalMac)
    }

    private func ouvrir(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }
}
