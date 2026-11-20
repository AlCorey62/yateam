import SwiftUI

/// Panneau de l'équipe, sur tous les bureaux, déplaçable à la souris (sa position est retenue).
/// Deux places au choix (Réglages) : posé sur le bureau, derrière toutes les fenêtres comme un
/// widget (par défaut), ou flottant au-dessus d'elles. Il n'active pas l'app : cliquer dessus ne
/// vole pas le clavier à la fenêtre où vous travaillez.
final class PanneauFlottant: NSPanel {
    init(surveillance: Surveillance, masquer: @escaping () -> Void, reglages: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 350, height: 420),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)

        let hote = NSHostingController(rootView: VuePanneau(surveillance: surveillance, masquer: masquer, reglages: reglages))
        hote.sizingOptions = [.preferredContentSize]
        contentViewController = hote

        appliquerPlace(surBureau: Preferences.partage.panneauSurBureau)
        setFrameAutosaveName("YaTeamPanneau")
        if !setFrameUsingName("YaTeamPanneau") { replacer() }
    }

    /// Sur le bureau : juste au-dessus des icônes du bureau, sous toutes les fenêtres, et immobile
    /// quand Mission Control écarte les fenêtres. Sinon : flottant, au-dessus des fenêtres.
    func appliquerPlace(surBureau: Bool) {
        if surBureau {
            isFloatingPanel = false
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else {
            isFloatingPanel = true
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        if isVisible { orderFrontRegardless() }
    }

    /// En bas à droite de l'écran principal.
    func replacer() {
        guard let ecran = NSScreen.main?.visibleFrame else { return }
        let taille = contentViewController?.view.fittingSize ?? frame.size
        setFrame(NSRect(x: ecran.maxX - taille.width - 16, y: ecran.minY + 16,
                        width: taille.width, height: taille.height), display: true)
    }

    override var canBecomeKey: Bool { true }

    /// SwiftUI garde les clics pour lui : « déplaçable par le fond » ne marche pas.
    /// Le panneau n'a aucun bouton, donc tout clic gauche le fait glisser
    /// (le clic droit garde son menu). La position est retenue par l'autosave.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

private struct VuePanneau: View {
    @ObservedObject var surveillance: Surveillance
    @ObservedObject private var preferences = Preferences.partage
    let masquer: () -> Void
    let reglages: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { contexte in
            ContenuPanneau(etats: surveillance.etats, maintenant: contexte.date, fond: .verre,
                           membres: preferences.membresAffiches)
        }
        .contextMenu {
            Button(Textes.t("widget.actualiser_quotas")) { surveillance.toutActualiser() }
            Button(Textes.t("widget.reglages")) { reglages() }
            Button(Textes.t("widget.masquer")) { masquer() }
            Divider()
            Button(Textes.t("widget.quitter")) { NSApp.terminate(nil) }
        }
    }
}
