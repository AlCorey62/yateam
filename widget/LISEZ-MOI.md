# Widget YaTeam

App SwiftUI pour la barre des menus et un panneau flottant (voir le README principal).
Paquet Swift : se construit avec les seuls outils de ligne de commande d'Apple.

```
./outils/construire.sh              # version finale → build/YaTeam.app
./outils/construire.sh --installer  # idem, puis copie dans Applications et lance
./outils/construire.sh --test       # version de test « YaTeam Preview » (identifiant .preview)
./outils/instantanes.sh             # captures du README, sans fenêtre (données de démonstration)
```

Instantanés à la main (version de test) :
`"build/YaTeam Preview.app/Contents/MacOS/YaTeam Preview" -YaTeamInstantane <dossier> [-reel] [-YaTeamLangues <dossier des traductions>] [-YaTeamLangue <code> | -YaTeamToutesLangues]`

Textes : les mêmes fichiers que le connecteur (`~/.claude/equipe/langues/<code>.json`, voir `Sources/Donnees/Textes.swift`) ; la langue vient de `config.json`, sinon de celle du Mac.

## Organisation

- `Sources/Donnees` : réglages (`~/.claude/equipe/config.json`), activité (fichiers d'état écrits par les scripts et le crochet de Claude Code), quotas (Claude, Codex, Antigravity).
- `Sources/Vues` : cartes du panneau et personnages animés (`Icones.swift`).
- `Sources/App` : app, panneau flottant, instantanés de test.

## Pièges

- **Animations** : jamais de `TimelineView` qui redessine les icônes dans le panneau (SwiftUI recalculait tout le panneau à chaque image : ~17 % de processeur). Chaque boucle est dessinée une seule fois (`Bobine`), puis jouée par Core Animation (~1 à 2 %). Les périodes de chaque animation doivent tomber juste dans la durée de sa boucle.
- **Personnages** : dessinés en code (`Canvas`) dans une boîte de 100 × 80 unités, avec un rendu « peluche » (lumière, ombre, bord duveteux). Ils ne doivent ressembler à aucun logo ni mascotte d'éditeur.
- **Mode clair** : le menu de la barre suit le système ; le contenu garde son fond sombre, et le panneau flottant est forcé en `darkAqua`.
- **Déplacer le panneau** : `isMovableByWindowBackground` ne marche pas avec SwiftUI (il garde les clics) ; `PanneauFlottant.sendEvent` lance donc `performDrag` sur tout clic gauche.
- **Relevés de quota** : `claude -p /usage` et `agy -p /quota` tournent depuis `~/.claude/equipe/atelier`, que le crochet de Claude Code ignore (sinon chaque relevé allumerait l'icône de Claude).
