import SwiftUI

/// Le panneau complet : un en-tête et une carte par membre.
struct ContenuPanneau: View {
    let etats: [Membre: EtatMembre]
    let maintenant: Date
    var tempsFige: Double?
    var fond: Fond = .verre
    /// Les cartes à afficher (Réglages : certaines peuvent être masquées).
    var membres: [Membre] = Membre.presents

    enum Fond {
        /// Panneau flottant : verre dépoli sombre.
        case verre
        /// Instantanés de test : fond uni (le verre n'est pas rendu hors fenêtre).
        case uni
        /// Menu de la barre : la fenêtre du menu a déjà son fond.
        case aucun
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("YaTeam").font(.system(size: 12, weight: .bold))
                Spacer()
                let actifs = membres.filter { etats[$0]?.auTravail == true }.count
                Text(actifs == 0 ? Textes.t("widget.tous_libres") : Textes.t("widget.n_au_travail", ["n": actifs]))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            ForEach(membres) { membre in
                CarteMembre(membre: membre, etat: etats[membre] ?? EtatMembre(),
                            maintenant: maintenant, tempsFige: tempsFige)
            }
        }
        .padding(10)
        .frame(width: 362)
        .background {
            switch fond {
            case .verre:
                ZStack { VerreDepoli(); Color.black.opacity(0.35) }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            case .uni: RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.11))
            case .aucun: EmptyView()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(fond == .aucun ? 0 : 0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

struct CarteMembre: View {
    let membre: Membre
    let etat: EtatMembre
    let maintenant: Date
    var tempsFige: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconeMembre(membre: membre, auTravail: etat.auTravail, enAttente: etat.enAttente, tempsFige: tempsFige)
                .frame(width: 58, height: 46)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(membre.nom).font(.system(size: 14, weight: .semibold))
                    Text(membre.role).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                }
                Statut(membre: membre, etat: etat, maintenant: maintenant, tempsFige: tempsFige)
                if membre.aUnQuota {
                    // Certains abonnements Claude n'ont plus de limite sur 5 h : quand /usage ne la
                    // renvoie pas, la ligne disparaît au lieu d'afficher « inconnu ».
                    if membre != .claude || etat.quota.cinqHeures != nil || etat.miseAJour == nil {
                        LigneJauge(titre: Textes.t("commun.cinq_heures"), fenetre: etat.quota.cinqHeures?.aLInstant(maintenant), maintenant: maintenant)
                    }
                    LigneJauge(titre: Textes.t("commun.semaine"), fenetre: etat.quota.semaine?.aLInstant(maintenant), maintenant: maintenant)
                } else {
                    LigneInfo(titre: Textes.t("widget.quota"), texte: Textes.t("widget.mac_sans_quota"))
                    LigneInfo(titre: Textes.t("widget.actions"), texte: texteActions)
                }
                if let second = etat.quotaSecondaire {
                    Text(etat.libelleSecondaire ?? Textes.t("widget.autre_reserve"))
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    if let f = second.cinqHeures {
                        LigneJauge(titre: Textes.t("commun.cinq_heures"), fenetre: f.aLInstant(maintenant), maintenant: maintenant, discrete: true)
                    }
                    if let f = second.semaine {
                        LigneJauge(titre: Textes.t("commun.semaine"), fenetre: f.aLInstant(maintenant), maintenant: maintenant, discrete: true)
                    }
                }
                piedDeCarte
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(etat.auTravail ? 0.085 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Palette.couleur(membre).opacity(etat.auTravail ? 0.55 : 0), lineWidth: 1))
    }

    private var texteActions: String {
        var texte = Textes.t("widget.n_aujourdhui", ["n": etat.actionsDuJour])
        if let date = etat.derniereActionDate {
            texte += " · " + Textes.t("widget.derniere", ["quand": Format.anciennete(date, maintenant)])
        }
        return texte
    }

    @ViewBuilder private var piedDeCarte: some View {
        if !membre.aUnQuota {
            if let action = etat.derniereAction {
                Text(action)
                    .font(.system(size: 9.5))
                    .foregroundStyle(etat.derniereActionReussie ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if let probleme = etat.probleme {
            Label(probleme, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(2)
        } else if let maj = etat.miseAJour {
            Text(Textes.t("widget.releve", ["quand": Format.anciennete(maj, maintenant)]))
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

/// « Au travail · 3 min », « Attend votre réponse » ou « Disponible ».
struct Statut: View {
    let membre: Membre
    let etat: EtatMembre
    let maintenant: Date
    var tempsFige: Double?

    var body: some View {
        HStack(spacing: 5) {
            if etat.auTravail {
                HStack(spacing: 5) {
                    PointsDeTravail(couleur: .white, tempsFige: tempsFige)
                    Text(texteTravail).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Palette.couleur(membre).melange(.black, 0.5)))
            } else if etat.enAttente {
                Image(systemName: "hand.raised.fill").font(.system(size: 9))
                Text(Textes.t("widget.attend")).font(.system(size: 10.5, weight: .medium))
            } else {
                Circle().fill(.secondary).frame(width: 5, height: 5)
                Text(Textes.t("widget.disponible")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(etat.enAttente && !etat.auTravail ? Color.orange : Color.primary)
    }

    private var texteTravail: String {
        var morceaux = [Textes.t("widget.au_travail")]
        if let depuis = etat.depuis { morceaux.append(Format.duree(maintenant.timeIntervalSince(depuis))) }
        if etat.sessionsActives > 1 { morceaux.append(Textes.t("widget.n_sessions", ["n": etat.sessionsActives])) }
        if let tache = etat.tache, !tache.isEmpty { morceaux.append(Textes.t("widget.citation", ["texte": tache])) }
        return morceaux.joined(separator: " · ")
    }
}

/// Trois points qui sautillent, comme quelqu'un qui écrit.
struct PointsDeTravail: View {
    let couleur: Color
    var tempsFige: Double?

    var body: some View {
        if let t = tempsFige { points(t) } else {
            PointsAnimes(couleur: NSColor(couleur)).frame(width: 16, height: 8)
        }
    }

    private func points(_ t: Double) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                Circle().fill(couleur).frame(width: 4, height: 4)
                    .offset(y: -2.5 * max(0, sin(t * 6 - Double(i) * 0.9)))
            }
        }
        .frame(height: 8)
    }
}

/// Les trois points, animés par Core Animation (rien à recalculer côté app).
struct PointsAnimes: NSViewRepresentable {
    let couleur: NSColor

    func makeNSView(context: Context) -> VuePoints { VuePoints(couleur: couleur) }
    func updateNSView(_ vue: VuePoints, context: Context) {}
}

final class VuePoints: NSView {
    private let couleur: NSColor

    init(couleur: NSColor) {
        self.couleur = couleur
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 8))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 8) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let calque = layer else { return }
        calque.sublayers?.forEach { $0.removeFromSuperlayer() }
        for i in 0..<3 {
            let point = CALayer()
            point.frame = CGRect(x: Double(i) * 6, y: 1, width: 4, height: 4)
            point.cornerRadius = 2
            point.backgroundColor = couleur.cgColor
            let saut = CAKeyframeAnimation(keyPath: "transform.translation.y")
            saut.values = [0, 2.5, 0, 0]
            saut.keyTimes = [0, 0.25, 0.5, 1]
            saut.duration = 1.05
            saut.repeatCount = .infinity
            saut.timeOffset = Double(2 - i) * 0.15
            point.add(saut, forKey: "saut")
            calque.addSublayer(point)
        }
    }
}

/// Une ligne de texte à la place des jauges (le Mac n'a pas de quota).
struct LigneInfo: View {
    let titre: String
    let texte: String

    var body: some View {
        HStack(spacing: 7) {
            Text(titre)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 48, alignment: .leading)
            Text(texte)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
    }
}

/// Une jauge horizontale : titre, barre, pourcentage utilisé, remise à zéro.
struct LigneJauge: View {
    let titre: String
    let fenetre: Fenetre?
    let maintenant: Date
    var discrete = false

    var body: some View {
        HStack(spacing: 7) {
            Text(titre)
                .font(.system(size: discrete ? 9.5 : 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    if let f = fenetre {
                        Capsule().fill(Palette.jauge(f.utilise).opacity(discrete ? 0.7 : 1))
                            .frame(width: max(f.utilise > 0 ? 4 : 0, geo.size.width * f.utilise))
                    }
                }
            }
            .frame(height: discrete ? 4 : 6)
            Text(fenetre.map { Textes.t("commun.pourcent", ["n": Int(($0.utilise * 100).rounded())]) } ?? "—")
                .font(.system(size: discrete ? 9.5 : 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(discrete ? .secondary : .primary)
                .frame(width: 36, alignment: .trailing)
            Text(Format.reinitialisation(fenetre, maintenant))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
                .lineLimit(1)
        }
    }
}

enum Format {
    static func duree(_ secondes: TimeInterval) -> String {
        let minutes = max(0, Int(secondes / 60))
        if minutes < 1 { return Textes.t("widget.a_l_instant") }
        if minutes < 60 { return Textes.t("widget.minutes", ["n": minutes]) }
        return Textes.t("widget.heures_minutes", ["h": minutes / 60, "m": String(format: "%02d", minutes % 60)])
    }

    static func reinitialisation(_ fenetre: Fenetre?, _ maintenant: Date) -> String {
        guard let fenetre else { return Textes.t("widget.inconnu") }
        guard let r = fenetre.reinitialisation else { return Textes.t("mcp.q_pas_entamee") }
        let reste = r.timeIntervalSince(maintenant)
        if reste < 60 { return "↻ " + Textes.t("widget.moins_d_une_minute") }
        if reste < 24 * 3600 { return "↻ " + duree(reste) }
        return "↻ " + jourHeure(r.addingTimeInterval(30))   // arrondi à la minute
    }

    static func anciennete(_ date: Date, _ maintenant: Date) -> String {
        let s = maintenant.timeIntervalSince(date)
        if s < 90 { return Textes.t("widget.a_l_instant") }
        if s < 3600 { return Textes.t("widget.il_y_a", ["n": Int(s / 60)]) }
        if Calendar.current.isDate(date, inSameDayAs: maintenant) { return Textes.t("widget.a_heure", ["heure": heure(date)]) }
        return Textes.t("widget.le_jour", ["jour": jourHeure(date)])
    }

    /// « 19h05 », « 19:05 »… selon la langue.
    static func heure(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Textes.t("commun.heure", ["h": c.hour ?? 0, "m": String(format: "%02d", c.minute ?? 0)])
    }

    /// « jeu. 19h05 », « Thu 19:05 », « 木 19:05 »…
    static func jourHeure(_ date: Date) -> String {
        let jours = Textes.t("commun.jours").split(separator: "|").map(String.init)
        let indice = (Calendar.current.component(.weekday, from: date) + 5) % 7   // lundi = 0
        let jour = jours.count == 7 ? jours[indice] : ""
        return "\(jour) \(heure(date))"
    }
}

/// Verre dépoli sombre façon HUD (fond du panneau flottant).
struct VerreDepoli: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
