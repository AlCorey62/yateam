import Foundation
import Combine

/// Rassemble l'état des membres et le tient à jour :
/// - activité (qui travaille) : toutes les 1,5 s, simple lecture de petits fichiers ;
/// - quota du chargé de projet ChatGPT : toutes les 15 s, lecture de la fin de l'historique Codex ;
/// - quotas de Claude et de Gemini : en lançant leur commande officielle (claude -p /usage,
///   agy -p /quota, sans appel au modèle), au démarrage, sur « Actualiser », peu après la fin
///   d'une tâche (au plus une fois toutes les 2 min) et sinon selon la fréquence choisie (Réglages) ;
/// - le Mac n'a pas de quota : on lit le compte de ses actions du jour avec son activité ;
/// - si Antigravity réclame une reconnexion Google, ses relevés se mettent en pause jusqu'à
///   « Actualiser » (jamais de page de connexion ouverte en boucle) ;
/// - après « Reconnecter… » (Réglages), Claude ou Gemini est relevé chaque minute pendant 15 min ;
/// - une notification quand un quota dépasse le seuil choisi (une fois par fenêtre de quota).
@MainActor
final class Surveillance: ObservableObject {
    @Published private(set) var etats: [Membre: EtatMembre] = [:]
    /// Antigravity a demandé une reconnexion : plus de relevé automatique tant qu'on n'a pas cliqué « Actualiser ».
    @Published private(set) var antigravityEnPause = false

    private let membres = Membre.presents
    private var minuteries: [Timer] = []
    private var releveEnCours: Set<Membre> = []
    private var dernierReleve: [Membre: Date] = [:]
    /// Relevés demandés par la fin d'une tâche, faits dès que l'écart minimal est passé.
    private var aRelever: Set<Membre> = []
    private let ecartMinimal: TimeInterval = 120
    /// Reconnexion lancée depuis les Réglages : relevé chaque minute jusqu'à cette heure.
    private var reconnexionJusqua: [Membre: Date] = [:]
    /// Alertes déjà envoyées : par fenêtre de quota, l'heure de remise à zéro concernée.
    private var alertesEnvoyees: [String: Double] =
        UserDefaults.standard.dictionary(forKey: "alertesEnvoyees") as? [String: Double] ?? [:]
    private var alertesEnCours: Set<String> = []
    private let preferences = Preferences.partage

    /// Membres dont le quota se relève en lançant leur programme (claude, agy).
    private var aReleverEnLancant: [Membre] { membres.filter { $0 == .claude || $0 == .antigravity } }

    init(demo: [Membre: EtatMembre]? = nil) {
        if let demo { etats = demo; return }
        for m in membres { etats[m] = EtatMembre() }
        etats[.antigravity]?.libelleSecondaire = Textes.t("widget.tiers", ["nom": Membre.antigravity.nom])
        lireActivite()
        lireQuotaCodex()
        aReleverEnLancant.forEach { releverQuota($0) }
        minuteries = [
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.lireActivite() }
            },
            Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.lireQuotaCodex() }
            },
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.releverSiPerime() }
            },
        ]
    }

    func toutActualiser() {
        lireActivite()
        lireQuotaCodex()
        aReleverEnLancant.forEach { releverQuota($0, manuel: true) }
    }

    /// Le Terminal vient de s'ouvrir sur la commande de connexion du membre.
    func attendreReconnexion(_ membre: Membre) {
        guard membre == .claude || membre == .antigravity else { return }
        reconnexionJusqua[membre] = Date().addingTimeInterval(15 * 60)
    }

    var quelquUnTravaille: Bool { etats.values.contains { $0.auTravail } }

    // MARK: Activité

    private func lireActivite() {
        for membre in membres {
            let a = membre == .claude ? SourceActivite.claude() : SourceActivite.chargeDeProjet(membre)
            guard var e = etats[membre] else { continue }
            let finissait = e.auTravail && !a.auTravail
            e.auTravail = a.auTravail
            e.enAttente = a.enAttente
            e.depuis = a.depuis
            e.tache = membre == .claude ? nil : a.tache
            e.sessionsActives = a.sessions
            if membre == .mac {
                let bilan = SourceActivite.bilanMac()
                e.actionsDuJour = bilan.actionsDuJour
                e.derniereAction = bilan.derniere
                e.derniereActionDate = bilan.date
                e.derniereActionReussie = bilan.reussie
            }
            if e != etats[membre] { etats[membre] = e }
            // Tâche terminée : ses chiffres de quota viennent de bouger.
            if finissait && membre.aUnQuota {
                if membre == .codex { lireQuotaCodex() } else { aRelever.insert(membre); releverSiPerime() }
            }
        }
    }

    // MARK: Quotas

    private func lireQuotaCodex() {
        guard var e = etats[.codex] else { return }
        if let (quota, date) = SourceCodex.lireQuota() {
            e.quota = quota
            e.miseAJour = date
            e.probleme = nil
        } else {
            e.probleme = Textes.t("widget.codex_aucun_releve", ["nom": Membre.codex.nom])
        }
        if e != etats[.codex] { etats[.codex] = e }
        verifierAlertes(.codex)
    }

    private func releverSiPerime() {
        let maintenant = Date()
        for m in aReleverEnLancant {
            let enReconnexion = (reconnexionJusqua[m] ?? .distantPast) > maintenant
            let ecoule = maintenant.timeIntervalSince(dernierReleve[m] ?? .distantPast)
            if ecoule >= (enReconnexion ? 60 : preferences.intervalle(m)) || (aRelever.contains(m) && ecoule >= ecartMinimal) {
                aRelever.remove(m)
                releverQuota(m, apres: enReconnexion ? 0 : 3, manuel: enReconnexion)
            }
        }
    }

    private func releverQuota(_ membre: Membre, apres delai: TimeInterval = 0, manuel: Bool = false) {
        if membre == .antigravity {
            if manuel { antigravityEnPause = false } else if antigravityEnPause { return }
        }
        guard !releveEnCours.contains(membre) else { return }
        releveEnCours.insert(membre)
        Task {
            if delai > 0 { try? await Task.sleep(for: .seconds(delai)) }
            defer { releveEnCours.remove(membre); dernierReleve[membre] = Date() }
            guard var e = etats[membre] else { return }
            do {
                switch membre {
                case .claude:
                    let r = try await SourceClaude.lireQuota()
                    e.quota = r.quota
                    if let s = r.semaineModele {
                        e.quotaSecondaire = Quota(cinqHeures: nil, semaine: s.fenetre)
                        e.libelleSecondaire = Textes.t("widget.limite_modele", ["modele": s.nom])
                    } else {
                        e.quotaSecondaire = nil
                    }
                case .antigravity:
                    let r = try await SourceAntigravity.lireQuota()
                    e.quota = r.gemini
                    e.quotaSecondaire = r.tiers
                case .codex, .mac:
                    return
                }
                e.miseAJour = Date()
                e.probleme = nil
                reconnexionJusqua[membre] = nil
            } catch {
                e.probleme = error.localizedDescription
                if membre == .antigravity, case .reconnexion? = error as? SourceAntigravity.Erreur {
                    antigravityEnPause = true
                }
            }
            // L'activité a pu changer pendant le relevé : on ne touche qu'aux quotas.
            guard var actuel = etats[membre] else { return }
            actuel.quota = e.quota
            actuel.quotaSecondaire = e.quotaSecondaire
            actuel.libelleSecondaire = e.libelleSecondaire
            actuel.miseAJour = e.miseAJour
            actuel.probleme = e.probleme
            etats[membre] = actuel
            verifierAlertes(membre)
        }
    }

    // MARK: Alertes

    /// Une notification par fenêtre de quota qui passe le seuil choisi dans les Réglages,
    /// une seule fois jusqu'à sa remise à zéro.
    private func verifierAlertes(_ membre: Membre) {
        let seuil = Double(preferences.seuilAlerte) / 100
        guard seuil > 0, let e = etats[membre] else { return }
        let maintenant = Date()
        var fenetres: [(String, Fenetre?)] = [(Textes.t("commun.cinq_heures"), e.quota.cinqHeures),
                                              (Textes.t("commun.semaine"), e.quota.semaine)]
        if let s = e.quotaSecondaire {
            let reserve = e.libelleSecondaire ?? Textes.t("widget.autre_reserve")
            fenetres += [("\(Textes.t("commun.cinq_heures")) (\(reserve))", s.cinqHeures),
                         ("\(Textes.t("commun.semaine")) (\(reserve))", s.semaine)]
        }
        for (nom, brute) in fenetres {
            guard let f = brute?.aLInstant(maintenant), f.utilise >= seuil,
                  let remise = f.reinitialisation else { continue }
            let cle = "\(membre.rawValue)|\(nom)"
            // La même fenêtre peut annoncer sa remise à zéro à quelques secondes près d'un relevé à l'autre.
            if let deja = alertesEnvoyees[cle], abs(deja - remise.timeIntervalSince1970) < 1800 { continue }
            guard !alertesEnCours.contains(cle) else { continue }
            alertesEnCours.insert(cle)
            let titre = Textes.t("widget.alerte_titre", ["nom": membre.nom, "pct": Int((f.utilise * 100).rounded()),
                                                          "fenetre": nom])
            let corps = Textes.t("widget.alerte_corps",
                                 ["quand": Format.reinitialisation(f, maintenant).replacingOccurrences(of: "↻ ", with: "")])
            // Notée comme envoyée seulement si elle est vraiment partie : des notifications refusées
            // puis autorisées doivent encore pouvoir prévenir pour cette fenêtre.
            Task {
                if await Alertes.envoyer(titre: titre, corps: corps) {
                    alertesEnvoyees[cle] = remise.timeIntervalSince1970
                    UserDefaults.standard.set(alertesEnvoyees, forKey: "alertesEnvoyees")
                }
                alertesEnCours.remove(cle)
            }
        }
    }
}
