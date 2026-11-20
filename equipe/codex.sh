#!/bin/zsh
# Chargé de projet ChatGPT, via le Codex CLI officiel d'OpenAI.
# Usage : codex.sh [dossier_de_travail] < consigne
# Lit la consigne sur l'entrée standard, travaille en lecture seule dans le dossier
# indiqué et n'affiche que sa réponse finale (messages dans la langue choisie).
# -s read-only : bac à sable de Codex (lecture seule, imposée par le système).
# --ignore-user-config : n'embarque pas les greffons de votre config.toml ; la connexion
# au compte ChatGPT reste celle de Codex (ce script ne lit aucun identifiant).
# Pas de --ephemeral : Codex inscrit ses compteurs de quota (5 h, semaine) dans son
# historique ~/.codex/sessions, que lit le widget.
emulate -L zsh
EQUIPE="$HOME/.claude/equipe"
PY=/usr/bin/python3
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
texte() { "$PY" -I "$EQUIPE/textes.py" texte "$@" 2>/dev/null || print -r -- "$1" }
dossier="${1:-$PWD}"
[[ -d "$dossier" ]] || { print -r -- "⚠️ $(texte script.dossier_introuvable dossier="$dossier")"; exit 1 }
nom=$("$PY" -I "$EQUIPE/reglages.py" nom codex 2>/dev/null || print Pesto)
programme=$("$PY" -I "$EQUIPE/reglages.py" programme codex 2>/dev/null || print codex)
command -v "$programme" >/dev/null 2>&1 || { print -r -- "⚠️ $(texte commun.absent_codex nom="$nom")"; exit 1 }
consigne=$(cat)
[[ -n "${consigne//[[:space:]]/}" ]] || { print -r -- "⚠️ $(texte script.consigne_vide)"; exit 1 }
reponse=$(mktemp -t equipe-codex)
journal=$(mktemp -t equipe-codex-journal)
chmod 600 "$reponse" "$journal"
"$EQUIPE/signaler.sh" codex debut "$consigne" $$ >/dev/null 2>&1
trap 'rm -f "$reponse" "$journal"; "$EQUIPE/signaler.sh" codex fin $$ >/dev/null 2>&1' EXIT
trap 'exit 143' INT TERM   # arrêt forcé (fermeture de l'app) : passe quand même par la fin ci-dessus

if print -r -- "$consigne" | "$programme" exec --ignore-user-config --skip-git-repo-check \
     -s read-only --color never -C "$dossier" -o "$reponse" - >"$journal" 2>&1 \
   && [[ -s "$reponse" ]]; then
  cat "$reponse"
else
  print -r -- "⚠️ $(texte script.echec_codex nom="$nom")"
  tail -20 "$journal"
  exit 1
fi
