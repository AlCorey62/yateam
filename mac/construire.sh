#!/bin/zsh
# Construit « YaTeam Mac » (YaTeamMac.app : Rappels, Calendrier, Apple Intelligence pour le membre Mac)
# avec les outils de ligne de commande d'Apple, et l'installe dans le dossier indiqué.
#
#   ./mac/construire.sh [dossier]      par défaut ~/.claude/equipe
#
# Signature ad hoc par défaut. macOS rattache les autorisations (Rappels, Calendrier) à la signature :
# l'app n'est donc reconstruite QUE si ses sources ont changé (empreinte gardée dans l'app), sinon
# chaque réinstallation ferait redemander l'accès. Pour signer avec un certificat Developer ID :
#   YATEAM_IDENTITE="Developer ID Application: Votre Nom (EQUIPE)" ./mac/construire.sh
# Sort avec le code 0 (construite ou déjà à jour), 3 (Swift introuvable) ou 1 (échec).
emulate -L zsh
set -e
ici="${0:A:h}"
destination="${1:-$HOME/.claude/equipe}"
app="$destination/YaTeamMac.app"

empreinte=$( { cd "$ici" && cat construire.sh YaTeamMac/main.swift YaTeamMac/Info.plist YaTeamMac/*.lproj/InfoPlist.strings
                print -r -- "essai=${YATEAM_ESSAI:-}" } | shasum -a 256 | cut -d' ' -f1)
if [[ -x "$app/Contents/MacOS/YaTeamMac" && "$(cat "$app/Contents/Resources/empreinte-sources" 2>/dev/null)" == "$empreinte" ]]; then
  print -r -- "deja-a-jour"
  exit 0
fi
xcrun --find swiftc >/dev/null 2>&1 || exit 3

tmp=$(mktemp -d -t yateam-mac)
trap 'rm -rf "$tmp"' EXIT
paquet="$tmp/YaTeamMac.app"
mkdir -p "$paquet/Contents/MacOS" "$paquet/Contents/Resources"
cp "$ici/YaTeamMac/Info.plist" "$paquet/Contents/Info.plist"
for dossier in "$ici"/YaTeamMac/*.lproj; do
  cp -R "$dossier" "$paquet/Contents/Resources/"
done
print -r -- "$empreinte" > "$paquet/Contents/Resources/empreinte-sources"
journal="$tmp/compilation.log"
# YATEAM_ESSAI=1 : version d'essai (commande « effacer-essai » pour nettoyer après un test réel).
essai=()
[[ -n ${YATEAM_ESSAI:-} ]] && essai=(-D ESSAI)
if ! xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" $essai \
     -o "$paquet/Contents/MacOS/YaTeamMac" "$ici/YaTeamMac/main.swift" >"$journal" 2>&1; then
  grep -E "error:" "$journal" | head -20 >&2 || cat "$journal" >&2
  exit 1
fi
if [[ -n "${YATEAM_IDENTITE:-}" ]]; then
  codesign --force --timestamp --sign "$YATEAM_IDENTITE" "$paquet" >/dev/null 2>&1
else
  codesign --force --sign - --identifier local.yateam.mac "$paquet" >/dev/null 2>&1
fi
mkdir -p "$destination"
if [[ -e "$app" ]]; then
  # L'ancienne version va à la Corbeille (récupérable), jamais supprimée définitivement.
  mkdir -p "$HOME/.Trash"
  mv "$app" "$HOME/.Trash/YaTeamMac $(date +%Y%m%d-%H%M%S).app"
fi
mv "$paquet" "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" \
  >/dev/null 2>&1 || true
print -r -- "construite"
