#!/bin/zsh
# YaTeam — désinstallation / uninstaller : retire exactement ce que install.sh a ajouté,
# avec une confirmation avant chaque étape et une sauvegarde de chaque fichier modifié.
# Les autres crochets, connecteurs, agents et le reste de CLAUDE.md ne sont pas touchés.
# Les dossiers et l'app retirés vont dans la Corbeille (rien n'est supprimé définitivement).
#
#   ./desinstaller.sh               désinstallation guidée
#   ./desinstaller.sh --oui | --yes tout accepter
#   ./desinstaller.sh --fenetres    une seule confirmation, dans une fenêtre (--windows)
emulate -L zsh
setopt pipe_fail

DEPOT=${0:A:h}
PY=/usr/bin/python3
OSASCRIPT=${YATEAM_TEST_OSASCRIPT:-/usr/bin/osascript}   # tests : fausses fenêtres à réponses écrites d'avance
EQUIPE="$HOME/.claude/equipe"
AGENTS="$HOME/.claude/agents"
REGLAGES_CODE="$HOME/.claude/settings.json"
CONFIG_APP="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
MANIFESTE="$EQUIPE/installation.json"
SAUVEGARDES="$EQUIPE/sauvegardes/$(date +%Y%m%d-%H%M%S)-desinstallation"
tout_oui=0
fenetres=0

case ${1:-} in
  -o|--oui|-y|--yes) tout_oui=1 ;;
  -f|--fenetres|--windows) fenetres=1 ;;
  "") ;;
  -h|--aide|--help) sed -n '2,10p' "$DEPOT/desinstaller.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) print -u2 "Option ? $1  (./desinstaller.sh --help)"; exit 2 ;;
esac

SCRIPT_BOUTONS='on run argv
  set AppleScript'"'"'s text item delimiters to "|"
  set boutons to text items of (item 2 of argv)
  set AppleScript'"'"'s text item delimiters to ""
  tell me to activate
  try
    set r to display dialog (item 1 of argv) buttons boutons default button (item 3 of argv) with title "YaTeam"
    return button returned of r
  on error number -128
    return "§ANNULE§"
  end try
end run'
fenetre() { "$OSASCRIPT" -e "$SCRIPT_BOUTONS" "$@" 2>/dev/null || print -r -- "§ANNULE§" }

if ! "$PY" -c 'import sys' 2>/dev/null; then
  print -u2 "Python (Apple) introuvable / not found:  xcode-select --install"
  exit 1
fi

# Langue de l'installation (sinon celle du Mac).
eval "$("$PY" -I "$DEPOT/equipe/textes.py" shell)"
t() {
  local s=${T[$1]-$1} kv
  shift
  for kv in "$@"; do s=${s//"{${kv%%=*}}"/${kv#*=}}; done
  print -r -- "$s"
}
titre() { print; print -P "%B${1//\%/%%}%b" }
info() { print -r -- "   $1" }
conf() { YATEAM_LANGUE=$LANGUE "$PY" -I "$DEPOT/outils/configurer.py" "$@" }
demander() {
  if (( tout_oui )); then print -r -- "▸ $1 → $(t inst.oui)"; return 0; fi
  local r
  while true; do
    read -r "r?▸ $1 $(t inst.choix) " || { print; return 1 }
    case ${r:l} in
      o|oui|y|yes|j|ja|s|si|sí|はい|是) return 0 ;;
      n|non|no|nein|nee|いいえ|否) return 1 ;;
      t|tout|a|all|alle|todo|tutto|すべて|全部) tout_oui=1; return 0 ;;
    esac
  done
}
# Met un fichier ou un dossier à la Corbeille (récupérable).
corbeille() {
  mkdir -p "$HOME/.Trash"
  mv "$1" "$HOME/.Trash/${1:t} $(date +%H.%M.%S)" && info "$(t desinst.a_la_corbeille chemin="$1")"
}

if (( ! tout_oui && ! fenetres )) && [[ ! -t 0 ]]; then
  print -u2 "$(t inst.pas_de_terminal)"
  exit 2
fi

print -P "%B$(t desinst.bienvenue)%b"
if (( fenetres )); then
  if [[ $(fenetre "$(t desinst.f_confirmer dossier="$EQUIPE")" "$(t inst.f_annuler)|$(t desinst.f_desinstaller)" \
          "$(t inst.f_annuler)") != "$(t desinst.f_desinstaller)" ]]; then
    print -r -- "   $(t desinst.f_annule)"
    exit 1
  fi
  tout_oui=1
fi

titre "1. $(t inst.titre_crochets)"
if demander "$(t desinst.question_crochets fichier="$REGLAGES_CODE")"; then
  conf retirer-crochets "$REGLAGES_CODE" "$SAUVEGARDES"
fi

titre "2. $(t inst.titre_connecteur)"
if demander "$(t desinst.question_connecteur)"; then
  conf retirer-connecteur "$CONFIG_APP" "$SAUVEGARDES"
  # Claude Code (Terminal) : seulement si l'entrée « equipe » est bien celle de YaTeam.
  chemin_claude=$(whence -p claude 2>/dev/null)
  [[ -z $chemin_claude ]] && chemin_claude=$("$PY" -I "$EQUIPE/reglages.py" programme claude 2>/dev/null)
  if [[ -n $chemin_claude ]] && whence -p "$chemin_claude" >/dev/null 2>&1 \
     && [[ $("$chemin_claude" mcp get equipe 2>/dev/null) == *"/.claude/equipe/mcp_equipe.py"* ]]; then
    "$chemin_claude" mcp remove -s user equipe >/dev/null 2>&1 && info "$(t desinst.connecteur_code_retire)"
  fi
fi

titre "3. $(t inst.titre_agents)"
if demander "$(t desinst.question_agents dossier="$AGENTS")"; then
  conf retirer-agents "$MANIFESTE" "$AGENTS" "$SAUVEGARDES"
fi

titre "4. $(t inst.titre_regle)"
if demander "$(t desinst.question_regle fichier="$CLAUDE_MD")"; then
  conf retirer-regle "$CLAUDE_MD" "$SAUVEGARDES"
fi

titre "5. $(t inst.titre_widget)"
apps=()
widget_note=$(conf lire "$MANIFESTE" widget 2>/dev/null)
for a in "$widget_note" "/Applications/YaTeam.app" "$HOME/Applications/YaTeam.app"; do
  [[ -n $a && -d $a && ${apps[(Ie)$a]} -eq 0 ]] && apps+=("$a")
done
if (( ${#apps} )); then
  info "$(t desinst.ouverture_session)"
  for a in $apps; do
    if demander "$(t desinst.question_widget app="$a")"; then
      pkill -x "YaTeam" 2>/dev/null
      corbeille "$a"
    fi
  done
else
  info "$(t desinst.aucun_widget)"
fi

titre "6. ~/.claude/equipe"
if [[ -d $EQUIPE ]]; then
  info "$(t desinst.contenu_dossier)"
  if demander "$(t desinst.question_dossier dossier="$EQUIPE")"; then
    corbeille "$EQUIPE"
  fi
else
  info "$(t desinst.deja_absent)"
fi

titre "$(t inst.titre_fin)"
info "$(t desinst.fin_app)"
info "$(t desinst.fin_cli)"
info "$(t desinst.fin_mac)"
if (( fenetres )); then
  fenetre "$(t desinst.f_fin)"$'\n\n'"$(t desinst.fin_app)"$'\n'"$(t desinst.fin_mac)" "$(t inst.f_ok)" "$(t inst.f_ok)" >/dev/null
fi
exit 0
