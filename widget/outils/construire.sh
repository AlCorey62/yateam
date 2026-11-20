#!/bin/zsh
# Construit le widget « YaTeam » avec les outils de ligne de commande d'Apple (sans Xcode).
#
#   ./outils/construire.sh              version finale → build/YaTeam.app
#   ./outils/construire.sh --installer  idem, puis copie dans /Applications (ou ~/Applications) et lance
#   ./outils/construire.sh --test       version de test « YaTeam Preview » (identifiant .preview, mode instantanés)
#
# Signature : ad hoc par défaut (l'app construite sur votre Mac s'ouvre sans alerte).
# Pour signer avec votre certificat Developer ID (facultatif) :
#   YATEAM_IDENTITE="Developer ID Application: Votre Nom (EQUIPE)" ./outils/construire.sh
set -e
cd "$(dirname "$0")/.."

mode=final
case "${1:-}" in
  --installer) mode=installer ;;
  --test) mode=test ;;
  "") ;;
  *) echo "Option inconnue : $1 (attendu : --installer ou --test)" >&2; exit 2 ;;
esac

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "⚠️ Swift est introuvable. Installez les outils de ligne de commande d'Apple : xcode-select --install" >&2
  exit 1
fi

if [[ $mode == test ]]; then
  configuration=debug; nom="YaTeam Preview"; identifiant="local.yateam.widget.preview"
else
  configuration=release; nom="YaTeam"; identifiant="local.yateam.widget"
fi

echo "Compilation du widget ($configuration), une à trois minutes…"
journal=$(mktemp -t yateam-compilation)
if ! swift build -c $configuration --product YaTeam >"$journal" 2>&1; then
  grep -E "error:" "$journal" | head -20 >&2
  echo "⚠️ La compilation a échoué (journal complet : $journal)" >&2
  exit 1
fi
grep -E "warning:" "$journal" | grep "/Sources/" | sort -u | head -20 || true
rm -f "$journal"
binaire="$(swift build -c $configuration --product YaTeam --show-bin-path)/YaTeam"
[[ -x "$binaire" ]] || { echo "⚠️ Programme compilé introuvable : $binaire" >&2; exit 1; }

app="build/$nom.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binaire" "$app/Contents/MacOS/$nom"
sed -e "s/__NOM__/$nom/g" -e "s/__IDENTIFIANT__/$identifiant/g" Support/Info.plist > "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

if [[ -n "${YATEAM_IDENTITE:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$YATEAM_IDENTITE" "$app"
else
  codesign --force --sign - "$app"
fi
echo "✅ $app"

if [[ $mode == installer ]]; then
  if [[ -w /Applications ]]; then destination=/Applications; else destination="$HOME/Applications"; mkdir -p "$destination"; fi
  pkill -x "$nom" 2>/dev/null || true
  if [[ -e "$destination/$nom.app" ]]; then
    # L'ancienne version va à la Corbeille (récupérable), jamais supprimée définitivement.
    mkdir -p "$HOME/.Trash"
    mv "$destination/$nom.app" "$HOME/.Trash/$nom $(date +%Y%m%d-%H%M%S).app" \
      || { echo "⚠️ Impossible de mettre l'ancienne version à la Corbeille : installation arrêtée." >&2; exit 1; }
    echo "Ancienne version mise à la Corbeille."
  fi
  cp -R "$app" "$destination/"
  echo "✅ Installé dans $destination. Lancement…"
  open "$destination/$nom.app"
fi
