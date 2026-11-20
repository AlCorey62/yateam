import Foundation

/// Textes du widget dans la langue choisie à l'installation : mêmes fichiers que le
/// connecteur et l'installateur (~/.claude/equipe/langues/<code>.json), valeurs à
/// insérer écrites {nom}. Langue : « langue » de config.json, sinon celle du Mac.
enum Textes {
    static let langues = ["en", "fr", "de", "es", "it", "ja", "zh"]

    /// Dossier des traductions (la version de test peut en désigner un autre : -YaTeamLangues <dossier>).
    static let dossier: URL = {
        #if DEBUG
        if let d = Instantane.argument("-YaTeamLangues") { return URL(fileURLWithPath: d) }
        #endif
        return Chemins.equipe.appendingPathComponent("langues")
    }()

    private(set) static var langue = langueInitiale()
    private static var catalogue = charger(langue)
    private static let secours = charger("en")

    private static func langueInitiale() -> String {
        #if DEBUG
        if let l = Instantane.argument("-YaTeamLangue"), langues.contains(l) { return l }
        #endif
        if let l = Reglages.langue, langues.contains(l) { return l }
        for preferee in Locale.preferredLanguages {
            let code = String(preferee.prefix(2)).lowercased()
            return langues.contains(code) ? code : "en"
        }
        return "en"
    }

    /// Change de langue (instantanés de test : une capture par langue).
    static func choisir(_ nouvelle: String) {
        guard langues.contains(nouvelle) else { return }
        langue = nouvelle
        catalogue = charger(nouvelle)
    }

    private static func charger(_ code: String) -> [String: String] {
        guard let donnees = try? Data(contentsOf: dossier.appendingPathComponent("\(code).json")),
              let objet = try? JSONSerialization.jsonObject(with: donnees) as? [String: Any] else { return [:] }
        return objet.compactMapValues { $0 as? String }
    }

    static func t(_ cle: String, _ valeurs: [String: Any] = [:]) -> String {
        var texte = catalogue[cle] ?? secours[cle] ?? cle
        for (nom, valeur) in valeurs {
            texte = texte.replacingOccurrences(of: "{\(nom)}", with: "\(valeur)")
        }
        return texte
    }

    /// Locale des dates (jours de la semaine).
    static var locale: Locale { Locale(identifier: langue == "zh" ? "zh-Hans" : langue) }
}
