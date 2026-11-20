import AppKit
import EventKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// YaTeam Mac : petite app sans fenêtre qui fait, pour le connecteur de YaTeam
// (~/.claude/equipe/mcp_equipe.py), tout le travail du membre « Mac », sans aucun raccourci à créer :
// Rappels et Calendrier (EventKit), Notes (AppleScript) et questions à Apple Intelligence (FoundationModels).
// Pas d'images : Image Playground refuse de dessiner pour les apps (« notSupported » sur macOS 27).
// Lancée par LaunchServices (`open`), elle a ses propres autorisations (Rappels ; Calendrier en écriture
// seule ; « Automatisation » pour Notes), demandées une fois. Rien ne quitte le Mac.
//
// Usage : open -W -n -g -a YaTeamMac.app --args <fichier de sortie> <commande> [arguments…]
//   capacites                                       ce que ce Mac sait faire (Apple Intelligence…)
//   autoriser                                       demande les accès (installation, au premier plan)
//   listes                                          listes de Rappels, avec le nombre d'éléments à faire
//   lire <liste> <0|1>                              éléments à faire (1 : avec les 50 derniers cochés)
//   ajouter <liste|""> <échéance|""> <élément>…     nouveaux éléments ; échéance « AAAA-MM-JJ[ HH:MM] »
//   cocher <liste> <1 cocher|0 décocher> <élément>… noms exacts (tous les doublons) ; ne supprime rien
//   evenement <titre> <début ISO> <fin ISO> <1 journée entière|0> <lieu> <notes>   calendrier par défaut
//   question <consignes> <texte>                    réponse d'Apple Intelligence
//   note <titre> <corps HTML> <dossier|"">          nouvelle note dans Notes
// Écrit un JSON dans le fichier de sortie : {"ok": true, …} ou {"ok": false, "code": "…", …}.
// Les messages sont rédigés par le connecteur, dans la langue choisie, d'après le code d'erreur.

let arguments = Array(CommandLine.arguments.dropFirst())   // pris tels quels : un élément peut commencer par « - »
let magasin = EKEventStore()
let lancement = Date()
let commande = arguments.count >= 2 ? arguments[1] : ""
let reste = Array(arguments.dropFirst(2))

func terminer(_ reponse: [String: Any]) -> Never {
    if let sortie = arguments.first,
       let donnees = try? JSONSerialization.data(withJSONObject: reponse, options: [.sortedKeys]) {
        try? donnees.write(to: URL(fileURLWithPath: sortie), options: .atomic)
    }
    exit(reponse["ok"] as? Bool == true ? 0 : 1)
}

func echec(_ code: String, _ details: [String: Any] = [:]) -> Never {
    terminer(details.merging(["ok": false, "code": code]) { _, nouveau in nouveau })
}

func rappels(_ predicat: NSPredicate) async -> [EKReminder] {
    await withCheckedContinuation { suite in
        magasin.fetchReminders(matching: predicat) { suite.resume(returning: $0 ?? []) }
    }
}

func liste(_ nom: String) -> EKCalendar {
    let trouvees = magasin.calendars(for: .reminder).filter { $0.title == nom }
    guard let calendrier = trouvees.first else { echec("liste_introuvable", ["nom": nom]) }
    guard trouvees.count == 1 else {
        echec("listes_homonymes", ["nom": nom, "comptes": trouvees.map { $0.source.title }.joined(separator: ", ")])
    }
    return calendrier
}

func echeance(_ r: EKReminder) -> String {
    guard let c = r.dueDateComponents, let a = c.year, let m = c.month, let j = c.day else { return "" }
    if let h = c.hour { return String(format: "%04d-%02d-%02d %02d:%02d", a, m, j, h, c.minute ?? 0) }
    return String(format: "%04d-%02d-%02d", a, m, j)
}

func description(_ r: EKReminder) -> [String: Any] {
    ["nom": r.title ?? "", "fait": r.isCompleted, "echeance": echeance(r), "note": r.notes ?? ""]
}

/// « AAAA-MM-JJ » ou « AAAA-MM-JJ HH:MM », heure locale du Mac.
func composants(_ texte: String) -> DateComponents? {
    let morceaux = texte.split(whereSeparator: { "- :T".contains($0) }).compactMap { Int($0) }
    guard morceaux.count == 3 || morceaux.count == 5 else { return nil }
    var c = DateComponents(calendar: Calendar.current, timeZone: TimeZone.current,
                           year: morceaux[0], month: morceaux[1], day: morceaux[2])
    if morceaux.count == 5 { c.hour = morceaux[3]; c.minute = morceaux[4] }
    guard c.isValidDate(in: Calendar.current) else { return nil }
    return c
}

func dateISO(_ texte: String) -> Date? {
    if let d = ISO8601DateFormatter().date(from: texte) { return d }
    if let c = composants(texte) { return Calendar.current.date(from: c) }
    return nil
}

/// Autorisation donnée trop tard (le connecteur a déjà répondu « pas de réponse ») : on ne modifie
/// rien, sinon une demande relancée entre-temps ferait un doublon.
func verifierDelai() {
    if Date().timeIntervalSince(lancement) > 20 { echec("autorisation_tardive") }
}

func accesRappels() async {
    do {
        guard try await magasin.requestFullAccessToReminders() else { echec("acces_rappels_refuse") }
    } catch {
        echec("acces_rappels_impossible", ["detail": error.localizedDescription])
    }
}

/// Une chaîne AppleScript : guillemets et barres obliques échappés, retours à la ligne remplacés.
func litteral(_ texte: String) -> String {
    let propre = texte.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    return "\"" + propre + "\""
}

/// Notes par AppleScript, depuis cette app : l'autorisation « Automatisation » est au nom de YaTeam Mac.
func scriptNotes(_ source: String) -> (String?, Int?, String?) {
    var erreur: NSDictionary?
    let resultat = NSAppleScript(source: source)?.executeAndReturnError(&erreur)
    if let erreur {
        return (nil, erreur[NSAppleScript.errorNumber] as? Int ?? 0, erreur[NSAppleScript.errorMessage] as? String)
    }
    return (resultat?.stringValue, nil, nil)
}

func disponibiliteIA() -> (Bool, String) {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        switch SystemLanguageModel.default.availability {
        case .available: return (true, "")
        case .unavailable(.deviceNotEligible): return (false, "appareil")
        case .unavailable(.appleIntelligenceNotEnabled): return (false, "desactivee")
        case .unavailable(.modelNotReady): return (false, "pas_prete")
        case .unavailable(let autre): return (false, "\(autre)")
        }
    }
    #endif
    return (false, "systeme")
}

func executer() async {
    switch commande {
    case "capacites":
        let (ia, raison) = disponibiliteIA()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        terminer(["ok": true, "apple_intelligence": ia, "raison": raison,
                  "macos": "\(v.majorVersion).\(v.minorVersion)"])

    case "autoriser":
        // À l'installation, au premier plan : fait apparaître les demandes d'accès (Rappels, puis Calendrier
        // en écriture seule) au moment où l'installateur les annonce, plutôt qu'à la première demande à Claude.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let rappels = (try? await magasin.requestFullAccessToReminders()) ?? false
        let calendrier = (try? await magasin.requestWriteOnlyAccessToEvents()) ?? false
        // Notes : une commande sans effet (compter les dossiers) fait apparaître la demande « Automatisation ».
        let (_, numero, _) = scriptNotes("tell application \"Notes\" to count folders")
        terminer(["ok": true, "rappels": rappels, "calendrier": calendrier, "notes": numero == nil])

    case "listes":
        await accesRappels()
        let aFaire = await rappels(magasin.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        var compte: [String: Int] = [:]
        for r in aFaire { compte[r.calendar.calendarIdentifier, default: 0] += 1 }
        let parDefaut = magasin.defaultCalendarForNewReminders()?.calendarIdentifier
        let listes = magasin.calendars(for: .reminder).map {
            ["nom": $0.title, "a_faire": compte[$0.calendarIdentifier] ?? 0,
             "par_defaut": $0.calendarIdentifier == parDefaut] as [String: Any]
        }
        terminer(["ok": true, "listes": listes])

    case "lire":
        await accesRappels()
        guard let nom = reste.first else { echec("arguments") }
        let calendrier = liste(nom)
        var elements = await rappels(magasin.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                                             calendars: [calendrier]))
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        var faitsEnTout = 0
        if reste.count > 1, reste[1] == "1" {
            let faits = await rappels(magasin.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil,
                                                                             calendars: [calendrier]))
            faitsEnTout = faits.count
            elements += faits.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }.prefix(50)
        }
        terminer(["ok": true, "liste": calendrier.title, "elements": elements.map(description), "faits_en_tout": faitsEnTout])

    case "ajouter":
        await accesRappels()
        verifierDelai()
        guard reste.count > 2 else { echec("arguments") }
        let calendrier: EKCalendar
        if reste[0].isEmpty {
            guard let parDefaut = magasin.defaultCalendarForNewReminders() else { echec("pas_de_liste_par_defaut") }
            calendrier = parDefaut
        } else {
            calendrier = liste(reste[0])
        }
        guard calendrier.allowsContentModifications else { echec("liste_verrouillee", ["nom": calendrier.title]) }
        var quand: DateComponents? = nil
        if !reste[1].isEmpty {
            guard let c = composants(reste[1]) else { echec("echeance_illisible", ["texte": reste[1]]) }
            quand = c
        }
        do {
            for titre in reste.dropFirst(2) {
                let r = EKReminder(eventStore: magasin)
                r.title = titre
                r.calendar = calendrier
                if let c = quand {
                    r.dueDateComponents = c
                    if c.hour != nil, let d = Calendar.current.date(from: c) { r.addAlarm(EKAlarm(absoluteDate: d)) }
                }
                try magasin.save(r, commit: false)
            }
            try magasin.commit()
        } catch {
            echec("enregistrement", ["detail": error.localizedDescription])
        }
        terminer(["ok": true, "liste": calendrier.title, "ajoutes": Array(reste.dropFirst(2))])

    case "cocher":
        await accesRappels()
        verifierDelai()
        guard reste.count > 2 else { echec("arguments") }
        let calendrier = liste(reste[0])
        let cocher = reste[1] == "1"
        let candidats = cocher
            ? await rappels(magasin.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendrier]))
            : await rappels(magasin.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: [calendrier]))
                .sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
        // Tous les éléments qui portent exactement ce nom (doublons d'une liste de courses compris).
        var faits: [String] = [], introuvables: [String] = [], dejaPris = Set<String>()
        do {
            for titre in reste.dropFirst(2) {
                let cibles = candidats.filter { $0.title == titre && !dejaPris.contains($0.calendarItemIdentifier) }
                if cibles.isEmpty { introuvables.append(titre) }
                for r in cibles {
                    dejaPris.insert(r.calendarItemIdentifier)
                    r.isCompleted = cocher
                    try magasin.save(r, commit: false)
                    faits.append(titre)
                }
            }
            try magasin.commit()
        } catch {
            echec("enregistrement", ["detail": error.localizedDescription])
        }
        terminer(["ok": true, "liste": calendrier.title, "faits": faits, "introuvables": introuvables])

    case "evenement":
        do {
            guard try await magasin.requestWriteOnlyAccessToEvents() else { echec("acces_calendrier_refuse") }
        } catch {
            echec("acces_calendrier_impossible", ["detail": error.localizedDescription])
        }
        verifierDelai()
        guard reste.count >= 6, !reste[0].isEmpty, let debut = dateISO(reste[1]), let fin = dateISO(reste[2]) else {
            echec("dates_illisibles")
        }
        guard let calendrier = magasin.defaultCalendarForNewEvents else { echec("pas_de_calendrier_par_defaut") }
        let e = EKEvent(eventStore: magasin)
        e.title = reste[0]
        e.startDate = debut
        e.endDate = fin
        e.isAllDay = reste[3] == "1"
        e.location = reste[4].isEmpty ? nil : reste[4]
        e.notes = reste[5].isEmpty ? nil : reste[5]
        e.calendar = calendrier
        do { try magasin.save(e, span: .thisEvent, commit: true) } catch {
            echec("enregistrement", ["detail": error.localizedDescription])
        }
        terminer(["ok": true, "calendrier": calendrier.title])

    case "question":
        guard reste.count >= 2, !reste[1].isEmpty else { echec("question_vide") }
        let (ia, raison) = disponibiliteIA()
        guard ia else { echec("ia_indisponible", ["raison": raison]) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: reste[0])
                let reponse = try await session.respond(to: reste[1])
                terminer(["ok": true, "reponse": reponse.content])
            } catch {
                echec("ia_erreur", ["detail": error.localizedDescription])
            }
        }
        #endif
        echec("ia_indisponible", ["raison": "systeme"])

    case "note":
        guard reste.count >= 3, !reste[0].isEmpty else { echec("arguments") }
        var source = "tell application \"Notes\"\n"
        if !reste[2].isEmpty {
            source += "if not (exists folder \(litteral(reste[2]))) then return \"§DOSSIER§\"\n"
            source += "make new note at folder \(litteral(reste[2])) with properties {name:\(litteral(reste[0])), body:\(litteral(reste[1]))}\n"
        } else {
            source += "make new note with properties {name:\(litteral(reste[0])), body:\(litteral(reste[1]))}\n"
        }
        source += "end tell\nreturn \"ok\""
        let (resultat, numero, message) = scriptNotes(source)
        if let numero {
            if numero == -1743 { echec("acces_notes_refuse") }
            echec("note_erreur", ["detail": message ?? "\(numero)"])
        }
        if resultat == "§DOSSIER§" { echec("dossier_notes", ["dossier": reste[2]]) }
        terminer(["ok": true])

    #if ESSAI
    case "effacer-essai":
        // Version d'essai seulement (construire.sh avec YATEAM_ESSAI=1) : efface le rappel d'essai, titre exact.
        guard let titre = reste.first, titre.hasPrefix("YaTeam – essai") else { echec("arguments") }
        await accesRappels()
        var n = 0
        for r in await rappels(magasin.predicateForReminders(in: nil)) where r.title == titre {
            try? magasin.remove(r, commit: false)
            n += 1
        }
        try? magasin.commit()
        terminer(["ok": true, "rappels_effaces": n])
    #endif

    default:
        echec("arguments")
    }
}

// Garde-fou : jamais plus que le connecteur n'attend, même si une demande d'autorisation reste sans
// réponse (le connecteur abandonne quelques secondes plus tard).
let delaiMax: Double = ["question": 40, "capacites": 15, "autoriser": 300][commande] ?? 35
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { await executer() }
DispatchQueue.main.asyncAfter(deadline: .now() + delaiMax) { echec("delai", ["s": Int(delaiMax)]) }
application.run()
