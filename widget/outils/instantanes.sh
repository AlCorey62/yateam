#!/bin/zsh
# Produit les captures du README (sans fenêtre à l'écran) : construit la version de test
# puis lui fait dessiner le panneau et les personnages dans docs/captures/, avec des
# données de démonstration, en anglais puis dans chacune des 7 langues.
set -e
cd "$(dirname "$0")/.."
./outils/construire.sh --test
depot="$(cd .. && pwd)"
sortie="$depot/docs/captures"
mkdir -p "$sortie"
app="build/YaTeam Preview.app/Contents/MacOS/YaTeam Preview"
"$app" -YaTeamInstantane "$sortie" -YaTeamLangues "$depot/equipe/langues" -YaTeamLangue en
"$app" -YaTeamInstantane "$sortie" -YaTeamLangues "$depot/equipe/langues" -YaTeamToutesLangues
# On ne garde que la planche des icônes et les captures par langue.
rm -f "$sortie"/{libres,travail-0,travail-1,travail-2,portraits}.png
ls -1 "$sortie"
