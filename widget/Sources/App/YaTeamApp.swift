import SwiftUI
import Combine
import ServiceManagement
import UserNotifications

/// « YaTeam » : quotas et activité de Claude et des membres de l'équipe (ChatGPT via Codex CLI,
/// Gemini via Antigravity CLI, le Mac), dans la barre des menus et dans un panneau posé sur le bureau.
@main
struct YaTeamApp: App {
    @NSApplicationDelegateAdaptor(Delegue.self) private var delegue

    var body: some Scene {
        MenuBarExtra {
            MenuEquipe(surveillance: delegue.surveillance, delegue: delegue)
        } label: {
            EtiquetteBarre(surveillance: delegue.surveillance)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class Delegue: NSObject, NSApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    let surveillance: Surveillance
    private var panneau: PanneauFlottant?
    private var abonnements = Set<AnyCancellable>()

    @Published var panneauVisible: Bool {
        didSet {
            UserDefaults.standard.set(panneauVisible, forKey: "panneauVisible")
            appliquerPanneau()
        }
    }

    override init() {
        #if DEBUG
        surveillance = Surveillance(demo: Instantane.demande && !Instantane.reel ? Instantane.etatsDemo() : nil)
        #else
        surveillance = Surveillance()
        #endif
        panneauVisible = UserDefaults.standard.object(forKey: "panneauVisible") as? Bool ?? true
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if Instantane.demande {
            Instantane.produire(surveillance: surveillance, delegue: self)
            return
        }
        #endif
        UNUserNotificationCenter.current().delegate = self
        appliquerPanneau()
        Preferences.partage.$panneauSurBureau.dropFirst()
            .sink { [weak self] surBureau in self?.panneau?.appliquerPlace(surBureau: surBureau) }
            .store(in: &abonnements)
    }

    func montrerReglages() {
        FenetreReglages.montrer(surveillance: surveillance, delegue: self)
    }

    func replacerPanneau() {
        if panneau == nil { panneauVisible = true }
        panneau?.replacer()
    }

    /// Les alertes de quota s'affichent même si l'app est au premier plan (fenêtre Réglages ouverte).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    private func appliquerPanneau() {
        if panneauVisible {
            if panneau == nil {
                panneau = PanneauFlottant(surveillance: surveillance,
                                          masquer: { [weak self] in self?.panneauVisible = false },
                                          reglages: { [weak self] in self?.montrerReglages() })
            }
            panneau?.orderFrontRegardless()
        } else {
            panneau?.orderOut(nil)
        }
    }
}

/// Icône de la barre des menus : l'équipe, et le quota de Claude (5 h s'il existe, sinon la semaine).
struct EtiquetteBarre: View {
    @ObservedObject var surveillance: Surveillance

    var body: some View {
        let quota = surveillance.etats[.claude]?.quota
        let claude = (quota?.cinqHeures ?? quota?.semaine)?.aLInstant(Date()).utilise
        HStack(spacing: 3) {
            Image(systemName: surveillance.quelquUnTravaille ? "person.3.sequence.fill" : "person.3.fill")
            if let claude { Text(Textes.t("commun.pourcent", ["n": Int((claude * 100).rounded())])) }
        }
    }
}

/// Fenêtre qui s'ouvre depuis la barre des menus.
struct MenuEquipe: View {
    @ObservedObject var surveillance: Surveillance
    @ObservedObject var delegue: Delegue
    @ObservedObject private var preferences = Preferences.partage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 20)) { contexte in
                ContenuPanneau(etats: surveillance.etats, maintenant: contexte.date, fond: .uni,
                               membres: preferences.membresAffiches)
            }
            Divider()
            Toggle(Textes.t("widget.afficher_panneau"), isOn: $delegue.panneauVisible)
            ToggleOuvertureSession()
            HStack {
                Button(Textes.t("widget.actualiser")) { surveillance.toutActualiser() }
                Button(Textes.t("widget.reglages")) { delegue.montrerReglages() }
                Spacer()
                Button(Textes.t("widget.quitter")) { NSApp.terminate(nil) }
            }
        }
        .padding(10)
        .frame(width: 382)
    }
}

/// « Ouvrir à l'ouverture de session », dans le menu et dans les Réglages.
struct ToggleOuvertureSession: View {
    @State private var actif = SMAppService.mainApp.status == .enabled
    @State private var erreur: String?

    var body: some View {
        Toggle(Textes.t("widget.ouvrir_session"), isOn: $actif)
            .onChange(of: actif) { _, oui in
                do {
                    if oui { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    erreur = nil
                } catch {
                    erreur = error.localizedDescription
                }
            }
        if let erreur {
            Text(erreur).font(.caption).foregroundStyle(.orange)
        }
    }
}
