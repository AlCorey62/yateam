import SwiftUI

/// Icône d'un membre dans les cartes. Au repos : une image fixe. Au travail : une
/// boucle d'images dessinées une seule fois, puis jouées par Core Animation —
/// l'app ne recalcule rien image par image (SwiftUI redessinait tout le panneau
/// à chaque image : ~17 % de processeur en continu).
/// Dessins maison qui évoquent chaque assistant (personnage en pixels pour Claude, petite bande
/// sautillante pour ChatGPT, étincelle pour Gemini, bulle de couleurs pour le Mac) ; ce ne sont pas
/// les logos officiels.
struct IconeMembre: View {
    let membre: Membre
    let auTravail: Bool
    var enAttente = false
    /// Pour les instantanés de test : fige l'animation à cet instant.
    var tempsFige: Double?

    var body: some View {
        if let t = tempsFige {
            IconeDessin(membre: membre, actif: auTravail, enAttente: enAttente, t: t)
        } else {
            IconeAnimee(membre: membre, auTravail: auTravail, enAttente: enAttente)
                .frame(width: Bobine.taille.width, height: Bobine.taille.height)
        }
    }
}

/// Une image de l'animation, à l'instant `t` (secondes depuis le début de la boucle).
struct IconeDessin: View {
    let membre: Membre
    let actif: Bool
    var enAttente = false
    let t: Double

    var body: some View {
        ZStack {
            if actif {
                GeometryReader { geo in
                    Circle()
                        .fill(RadialGradient(colors: [Palette.couleur(membre).opacity(0.5), .clear], center: .center,
                                             startRadius: 0, endRadius: min(geo.size.width, geo.size.height) * 0.5))
                        .scaleEffect(1.05 + 0.1 * sin(2 * .pi * t / Bobine.periodeHalo(membre)))
                }
            }
            Canvas { gc, taille in
                let tt = actif ? t : 0
                switch membre {
                case .claude: IconeMembre.claude(gc, taille, tt, actif: actif)
                case .codex: IconeMembre.codex(gc, taille, tt, actif: actif)
                case .antigravity: IconeMembre.antigravity(gc, taille, tt, actif: actif)
                case .mac: IconeMembre.mac(gc, taille, tt, actif: actif)
                }
            }
        }
        .opacity(actif || enAttente ? 1 : 0.85)
        .saturation(actif || enAttente ? 1 : 0.7)
    }
}

/// Les boucles d'animation, dessinées une fois puis gardées en mémoire.
/// Chaque animation est construite sur des périodes qui tombent juste dans la
/// boucle, pour qu'elle reparte sans à-coup.
@MainActor
enum Bobine {
    static let taille = CGSize(width: 58, height: 46)
    static let echelle: CGFloat = 2

    struct Boucle {
        let images: [CGImage]
        let duree: Double
    }

    static func duree(_ m: Membre) -> Double {
        switch m { case .claude: 6; case .codex: 3.6; case .antigravity: 4; case .mac: 3 }
    }

    static func cadence(_ m: Membre) -> Double {
        switch m { case .claude: 12; case .codex: 15; case .antigravity: 15; case .mac: 15 }
    }

    static func periodeHalo(_ m: Membre) -> Double {
        switch m { case .claude: 1.5; case .codex: 1.2; case .antigravity: 2; case .mac: 1.5 }
    }

    private static var fixes: [String: CGImage] = [:]
    private static var boucles: [Membre: Task<Boucle?, Never>] = [:]

    static func imageFixe(_ m: Membre, enAttente: Bool) -> CGImage? {
        let cle = "\(m.rawValue)-\(enAttente)"
        if let image = fixes[cle] { return image }
        let image = rendre(IconeDessin(membre: m, actif: false, enAttente: enAttente, t: 0))
        fixes[cle] = image
        return image
    }

    static func boucle(_ m: Membre) async -> Boucle? {
        if let tache = boucles[m] { return await tache.value }
        let tache = Task<Boucle?, Never> { @MainActor in
            let n = Int((duree(m) * cadence(m)).rounded())
            var images: [CGImage] = []
            for k in 0..<n {
                if let image = rendre(IconeDessin(membre: m, actif: true, t: Double(k) / cadence(m))) {
                    images.append(image)
                }
                if k % 4 == 3 { await Task.yield() }   // ne pas figer l'interface pendant le dessin
            }
            return images.count == n ? Boucle(images: images, duree: duree(m)) : nil
        }
        boucles[m] = tache
        return await tache.value
    }

    private static func rendre(_ vue: some View) -> CGImage? {
        let rendu = ImageRenderer(content: vue.frame(width: taille.width, height: taille.height))
        rendu.scale = echelle
        return rendu.cgImage
    }
}

/// Calque Core Animation qui affiche l'image fixe ou joue la boucle.
struct IconeAnimee: NSViewRepresentable {
    let membre: Membre
    let auTravail: Bool
    let enAttente: Bool

    func makeNSView(context: Context) -> VueIcone { VueIcone(membre: membre) }

    func updateNSView(_ vue: VueIcone, context: Context) {
        vue.appliquer(auTravail: auTravail, enAttente: enAttente)
    }
}

final class VueIcone: NSView {
    let membre: Membre
    private var etat: (travail: Bool, attente: Bool)?
    private var tache: Task<Void, Never>?

    init(membre: Membre) {
        self.membre = membre
        super.init(frame: NSRect(origin: .zero, size: Bobine.taille))
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.contentsScale = Bobine.echelle
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override var intrinsicContentSize: NSSize { Bobine.taille }

    /// Une fenêtre refermée puis rouverte (menu de la barre) perd ses animations : on les remet.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let e = etat else { return }
        etat = nil
        appliquer(auTravail: e.travail, enAttente: e.attente)
    }

    @MainActor
    func appliquer(auTravail: Bool, enAttente: Bool) {
        if let e = etat, e.travail == auTravail, e.attente == enAttente { return }
        etat = (auTravail, enAttente)
        tache?.cancel()
        guard let calque = layer else { return }
        calque.removeAllAnimations()
        calque.contents = Bobine.imageFixe(membre, enAttente: enAttente && !auTravail)
        if enAttente && !auTravail {
            let clignote = CABasicAnimation(keyPath: "opacity")
            clignote.fromValue = 1
            clignote.toValue = 0.4
            clignote.duration = 0.7
            clignote.autoreverses = true
            clignote.repeatCount = .infinity
            calque.add(clignote, forKey: "attente")
        }
        guard auTravail else { return }
        let membre = self.membre
        tache = Task { @MainActor [weak self] in
            guard let boucle = await Bobine.boucle(membre), !Task.isCancelled,
                  let calque = self?.layer else { return }
            let film = CAKeyframeAnimation(keyPath: "contents")
            film.values = boucle.images
            film.calculationMode = .discrete
            film.duration = boucle.duree
            film.repeatCount = .infinity
            calque.contents = boucle.images.first
            calque.add(film, forKey: "travail")
        }
    }
}


extension IconeMembre {
    // MARK: Claude — le petit personnage en pixels de Claude Code, qui marche sur place

    /// Grille de 14 × 10 pixels : corps 10 × 7, deux yeux, deux bras, quatre pattes.
    static func claude(_ gc: GraphicsContext, _ taille: CGSize, _ t: Double, actif: Bool) {
        let colonnes = 14.0, lignes = 10.0
        let u = min(taille.width / colonnes, taille.height / lignes) * 0.96
        let ox = (taille.width - colonnes * u) / 2
        let oy = (taille.height - lignes * u) / 2
        func pixels(_ x: Double, _ y: Double, _ l: Double, _ h: Double, _ couleur: Color) {
            // Léger recouvrement pour éviter les liserés entre pixels voisins.
            gc.fill(Path(CGRect(x: ox + x * u - 0.25, y: oy + y * u - 0.25, width: l * u + 0.5, height: h * u + 0.5)),
                    with: .color(couleur))
        }
        // Au travail : 3 pas par seconde, pattes en alternance, bras qui s'agitent.
        let pas = actif ? Int(floor(t * 6)) % 2 : 0
        let clignement = actif && t.truncatingRemainder(dividingBy: 3) < 0.14
        let r = sin(2 * .pi * t / 6)
        let regard: Double = actif ? (r > 0.6 ? 1 : (r < -0.6 ? -1 : 0)) : 0
        let orange = Palette.claude
        let yeux = Color(white: 0.08)

        // Corps
        pixels(2, 0, 10, 7, orange)
        // Bras (levés un pas sur deux)
        let yBras: Double = pas == 1 ? 2 : 3
        pixels(0, yBras, 2, 2, orange)
        pixels(12, actif ? (pas == 1 ? 3 : 2) : 3, 2, 2, orange)
        // Pattes : une paire au sol, l'autre levée, puis on échange
        for (i, x) in [3.0, 5.0, 8.0, 10.0].enumerated() {
            let levee = actif && (i % 2 == pas)
            pixels(x, 7, 1, levee ? 2 : 3, orange)
        }
        // Yeux (qui regardent de côté et clignent de temps en temps)
        let hYeux: Double = clignement ? 0.6 : 2
        let yYeux: Double = clignement ? 3.2 : 2
        pixels(4 + regard, yYeux, 1, hYeux, yeux)
        pixels(9 + regard, yYeux, 1, hYeux, yeux)
    }

    // MARK: ChatGPT (Codex) — une petite bande de quatre « dots » en feutrine, qui sautillent comme des points de saisie

    static func codex(_ gc: GraphicsContext, _ taille: CGSize, _ t: Double, actif: Bool) {
        let n = 4.0
        let chevauchement = 0.14
        let l = taille.width / (n - chevauchement * (n - 1))   // largeur d'un dot
        let h = l * 1.12
        let sol = taille.height * 0.84
        let clignement = actif && t.truncatingRemainder(dividingBy: 3.6) < 0.13
        for i in 0..<4 {
            let phase = 2 * .pi * t / 1.2 - Double(i) * 0.95
            let saut = actif ? max(0, sin(phase)) : 0                 // 0 au sol … 1 en haut
            let etirement = actif ? 1 + 0.12 * (saut - 0.35) : 1       // écrasé à l'atterrissage
            var g = gc
            g.translateBy(x: l / 2 + Double(i) * l * (1 - chevauchement), y: sol - saut * taille.height * 0.2)
            g.scaleBy(x: 2 - etirement, y: etirement)
            switch i {
            case 0: dotBleu(g, l, h, clignement)
            case 1: dotVert(g, l, h, clignement, regard: actif ? sin(2 * .pi * t / 3.6) : 0)
            case 2: dotJaune(g, l, h)
            default: dotRose(g, l, h)
            }
        }
    }

    /// Teinte unie + reflet doux, pour l'effet « feutrine ».
    private static func feutre(_ g: GraphicsContext, _ forme: Path, _ couleur: Color, _ l: Double, _ h: Double) {
        g.fill(forme, with: .color(couleur))
        g.fill(forme, with: .radialGradient(Gradient(colors: [.white.opacity(0.32), .clear]),
                                            center: CGPoint(x: -l * 0.18, y: -h * 0.62),
                                            startRadius: 0, endRadius: l * 0.6))
    }

    /// Bleu au béret noir, deux petits yeux.
    private static func dotBleu(_ g: GraphicsContext, _ l: Double, _ h: Double, _ clignement: Bool) {
        let corps = Path(roundedRect: CGRect(x: -l / 2, y: -h * 0.74, width: l, height: h * 0.74), cornerRadius: l * 0.4)
        feutre(g, corps, Color(red: 0.13, green: 0.42, blue: 1.0), l, h)
        let noir = Color(white: 0.07)
        g.fill(Path(ellipseIn: CGRect(x: -l * 0.46, y: -h * 0.93, width: l * 0.86, height: h * 0.3)), with: .color(noir))
        g.fill(Path(ellipseIn: CGRect(x: -l * 0.1, y: -h * 1.03, width: l * 0.17, height: l * 0.17)), with: .color(noir))
        let hy = clignement ? l * 0.04 : l * 0.16
        for x in [-0.17, 0.17] {
            g.fill(Path(ellipseIn: CGRect(x: l * x - l * 0.055, y: -h * 0.4 - hy / 2, width: l * 0.11, height: hy)),
                   with: .color(noir))
        }
    }

    /// Vert aux gros yeux ronds posés sur le dessus.
    private static func dotVert(_ g: GraphicsContext, _ l: Double, _ h: Double, _ clignement: Bool, regard: Double) {
        let vert = Color(red: 0.55, green: 0.86, blue: 0.0)
        var forme = Path(roundedRect: CGRect(x: -l / 2, y: -h * 0.66, width: l, height: h * 0.66), cornerRadius: l * 0.36)
        for x in [-0.22, 0.22] {
            forme.addEllipse(in: CGRect(x: l * x - l * 0.21, y: -h * 0.86, width: l * 0.42, height: l * 0.42))
        }
        feutre(g, forme, vert, l, h)
        for x in [-0.22, 0.22] {
            let c = CGPoint(x: l * x, y: -h * 0.86 + l * 0.21)
            if clignement {
                g.fill(Path(CGRect(x: c.x - l * 0.14, y: c.y - l * 0.02, width: l * 0.28, height: l * 0.04)),
                       with: .color(Color(white: 0.07)))
            } else {
                g.fill(Path(ellipseIn: CGRect(x: c.x - l * 0.15, y: c.y - l * 0.15, width: l * 0.3, height: l * 0.3)),
                       with: .color(.white))
                let p = CGPoint(x: c.x + regard * l * 0.06, y: c.y + l * 0.02)
                g.fill(Path(ellipseIn: CGRect(x: p.x - l * 0.075, y: p.y - l * 0.075, width: l * 0.15, height: l * 0.15)),
                       with: .color(Color(white: 0.07)))
            }
        }
    }

    /// Jaune en triangle, lunettes rondes et yeux fermés souriants.
    private static func dotJaune(_ g: GraphicsContext, _ l: Double, _ h: Double) {
        var tri = Path()
        tri.move(to: CGPoint(x: 0, y: 0))
        tri.addArc(tangent1End: CGPoint(x: l / 2, y: 0), tangent2End: CGPoint(x: 0, y: -h * 0.92), radius: l * 0.12)
        tri.addArc(tangent1End: CGPoint(x: 0, y: -h * 0.92), tangent2End: CGPoint(x: -l / 2, y: 0), radius: l * 0.2)
        tri.addArc(tangent1End: CGPoint(x: -l / 2, y: 0), tangent2End: CGPoint(x: 0, y: 0), radius: l * 0.12)
        tri.closeSubpath()
        feutre(g, tri, Color(red: 1.0, green: 0.76, blue: 0.08), l, h)
        let noir = Color(white: 0.07)
        let trait = StrokeStyle(lineWidth: max(0.8, l * 0.05), lineCap: .round)
        var lunettes = Path()
        for x in [-0.17, 0.17] {
            lunettes.addEllipse(in: CGRect(x: l * x - l * 0.13, y: -h * 0.36 - l * 0.13, width: l * 0.26, height: l * 0.26))
        }
        lunettes.move(to: CGPoint(x: -l * 0.04, y: -h * 0.37))
        lunettes.addLine(to: CGPoint(x: l * 0.04, y: -h * 0.37))
        g.stroke(lunettes, with: .color(noir), style: trait)
        var yeux = Path()
        for x in [-0.17, 0.17] {
            yeux.addArc(center: CGPoint(x: l * x, y: -h * 0.37), radius: l * 0.06,
                        startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
        }
        g.stroke(yeux, with: .color(noir), style: StrokeStyle(lineWidth: max(0.7, l * 0.035), lineCap: .round))
    }

    /// Rose en cœur, lunettes noires.
    private static func dotRose(_ g: GraphicsContext, _ l: Double, _ h: Double) {
        var coeur = Path()
        coeur.move(to: CGPoint(x: 0, y: -h * 0.02))
        coeur.addCurve(to: CGPoint(x: -l / 2, y: -h * 0.55), control1: CGPoint(x: -l * 0.12, y: -h * 0.1),
                       control2: CGPoint(x: -l / 2, y: -h * 0.3))
        coeur.addCurve(to: CGPoint(x: 0, y: -h * 0.68), control1: CGPoint(x: -l / 2, y: -h * 0.88),
                       control2: CGPoint(x: -l * 0.06, y: -h * 0.9))
        coeur.addCurve(to: CGPoint(x: l / 2, y: -h * 0.55), control1: CGPoint(x: l * 0.06, y: -h * 0.9),
                       control2: CGPoint(x: l / 2, y: -h * 0.88))
        coeur.addCurve(to: CGPoint(x: 0, y: -h * 0.02), control1: CGPoint(x: l / 2, y: -h * 0.3),
                       control2: CGPoint(x: l * 0.12, y: -h * 0.1))
        coeur.closeSubpath()
        feutre(g, coeur, Color(red: 1.0, green: 0.2, blue: 0.68), l, h)
        let noir = Color(white: 0.07)
        for x in [-0.17, 0.17] {
            g.fill(Path(ellipseIn: CGRect(x: l * x - l * 0.12, y: -h * 0.47 - l * 0.12, width: l * 0.24, height: l * 0.24)),
                   with: .color(noir))
        }
        var pont = Path()
        pont.move(to: CGPoint(x: -l * 0.06, y: -h * 0.48))
        pont.addLine(to: CGPoint(x: l * 0.06, y: -h * 0.48))
        g.stroke(pont, with: .color(noir), style: StrokeStyle(lineWidth: max(0.8, l * 0.045)))
    }

    // MARK: Gemini (Antigravity) — étincelle à quatre branches en dégradé, qui scintille

    static func antigravity(_ gc: GraphicsContext, _ taille: CGSize, _ t: Double, actif: Bool) {
        let c = CGPoint(x: taille.width / 2, y: taille.height / 2)
        let demi = min(taille.width, taille.height) / 2
        let echelle = actif ? 0.88 + 0.12 * sin(2 * .pi * t / 2) : 1
        let r = demi * 0.74 * echelle
        let k = r * 0.11
        var etoile = Path()
        etoile.move(to: CGPoint(x: 0, y: -r))
        etoile.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: k, y: -k))
        etoile.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: k, y: k))
        etoile.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -k, y: k))
        etoile.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: -k, y: -k))
        etoile.closeSubpath()
        let angle = actif ? sin(2 * .pi * t / 4) * 0.3 : 0
        let placement = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle)
        let degrade = Gradient(colors: [Palette.geminiBleu, Palette.geminiViolet, Palette.geminiRose])
        gc.fill(etoile.applying(placement),
                with: .linearGradient(degrade, startPoint: CGPoint(x: c.x - r, y: c.y - r),
                                      endPoint: CGPoint(x: c.x + r, y: c.y + r)))
        guard actif else { return }
        // Petites étincelles en orbite
        for i in 0..<3 {
            let a = 2 * .pi * t / 4 + Double(i) * 2 * .pi / 3
            let p = CGPoint(x: c.x + cos(a) * demi * 0.86, y: c.y + sin(a) * demi * 0.86)
            let s = demi * 0.14 * (0.6 + 0.4 * abs(sin(2 * .pi * t / 2 + Double(i))))
            var petite = Path()
            petite.move(to: CGPoint(x: p.x, y: p.y - s))
            petite.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: p)
            petite.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: p)
            petite.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: p)
            petite.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: p)
            gc.fill(petite, with: .color(i == 0 ? Palette.geminiBleu : (i == 1 ? Palette.geminiViolet : Palette.geminiRose)))
        }
    }
}

extension IconeMembre {
    // MARK: Le Mac — une bulle de verre sombre où ondulent trois vagues de couleur, anneau irisé

    static func mac(_ gc: GraphicsContext, _ taille: CGSize, _ t: Double, actif: Bool) {
        let c = CGPoint(x: taille.width / 2, y: taille.height / 2)
        let r = min(taille.width, taille.height) / 2 * 0.86
        let bulle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        gc.fill(bulle, with: .radialGradient(Gradient(colors: [Color(red: 0.11, green: 0.09, blue: 0.24), Color(white: 0.03)]),
                                             center: c, startRadius: 0, endRadius: r))
        var vagues = gc
        vagues.clip(to: bulle)
        vagues.blendMode = .plusLighter
        // Au travail : les vagues glissent (périodes 1,5, 1 et 3 s) et changent de hauteur
        // (3 s) ; tout tombe juste dans la boucle de 3 s.
        let couleurs = [Palette.macRose, Palette.macCyan, Palette.macViolet]
        let periodes = [1.5, 1.0, 3.0]
        for i in 0..<3 {
            let phase = actif ? 2 * .pi * t / periodes[i] : Double(i) * 1.3
            let hauteur = r * (actif ? 0.34 + 0.2 * sin(2 * .pi * t / 3 + Double(i) * 2.1) : 0.15)
            let ondes = 1.6 + Double(i) * 0.5
            var crete: [CGPoint] = []
            for j in 0...36 {
                let x = -r + 2 * r * Double(j) / 36
                let enveloppe = pow(1 - pow(x / r, 2), 2)   // nulle sur les bords de la bulle
                crete.append(CGPoint(x: c.x + x, y: c.y - hauteur * enveloppe * sin(ondes * .pi * x / r + phase)))
            }
            var forme = Path()
            forme.move(to: crete[0])
            for p in crete.dropFirst() { forme.addLine(to: p) }
            for p in crete.reversed() { forme.addLine(to: CGPoint(x: p.x, y: 2 * c.y - p.y)) }
            forme.closeSubpath()
            vagues.fill(forme, with: .color(couleurs[i].opacity(actif ? 0.8 : 0.6)))
        }
        vagues.fill(bulle, with: .radialGradient(Gradient(colors: [.white.opacity(actif ? 0.2 : 0.1), .clear]),
                                                 center: c, startRadius: 0, endRadius: r * 0.45))
        let irise = Gradient(colors: [Palette.macRose, Color(red: 1, green: 0.62, blue: 0.22), Palette.macCyan,
                                      Palette.macViolet, Palette.macRose])
        gc.stroke(bulle, with: .conicGradient(irise, center: c, angle: .radians(actif ? 2 * .pi * t / 3 : 0)),
                  lineWidth: max(1.2, r * 0.09))
    }
}

extension Color {
    /// Mélange deux couleurs (`part` = 0 : cette couleur, 1 : l'autre). Compatible macOS 14.
    func melange(_ autre: Color, _ part: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let b = NSColor(autre).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: a.blended(withFraction: part, of: b) ?? a)
    }
}

enum Palette {
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)      // orange Claude
    static let codex = Color(red: 0.063, green: 0.639, blue: 0.498)       // vert ChatGPT
    static let geminiBleu = Color(red: 0.259, green: 0.522, blue: 0.957)
    static let geminiViolet = Color(red: 0.608, green: 0.447, blue: 0.796)
    static let geminiRose = Color(red: 0.851, green: 0.396, blue: 0.439)
    static let macRose = Color(red: 0.98, green: 0.25, blue: 0.62)
    static let macCyan = Color(red: 0.2, green: 0.78, blue: 1.0)
    static let macViolet = Color(red: 0.5, green: 0.38, blue: 1.0)

    static func couleur(_ membre: Membre) -> Color {
        switch membre {
        case .claude: claude
        case .codex: codex
        case .antigravity: geminiViolet
        case .mac: macRose
        }
    }

    /// Couleur d'une jauge selon la part consommée.
    static func jauge(_ utilise: Double) -> Color {
        if utilise >= 0.85 { return Color(red: 1, green: 0.27, blue: 0.23) }
        if utilise >= 0.6 { return Color(red: 1, green: 0.62, blue: 0.04) }
        return Color(red: 0.2, green: 0.78, blue: 0.35)
    }
}
