#!/bin/zsh
# YaTeam — installation / installer.
# Claude devient chef de projet et travaille avec les membres choisis : ChatGPT (Codex CLI) et
# Gemini (Antigravity CLI), chargés de projet en lecture seule, et le Mac lui-même (Rappels,
# Calendrier, Notes, apps, Apple Intelligence).
#
#   double-clic sur « Installer YaTeam »  fenêtres de questions, aucune commande à taper
#   ./install.sh                          installation guidée dans le Terminal (accord avant chaque étape)
#   ./install.sh --fenetres               questions dans des fenêtres (--windows)
#   ./install.sh --oui | --yes            tout accepter / accept everything
#   ./install.sh --ia chatgpt,gemini,mac  membres à activer / members to enable (--ai)
#   ./install.sh --langue de              langue / language : en fr de es it ja zh (celle du Mac par défaut)
#   ./install.sh --nom-chatgpt Bagel --nom-gemini Nori --nom-mac Mango
#                                         (ou / or --chatgpt-name, --gemini-name, --mac-name)
#   ./install.sh --nouveaux-noms          nouveaux noms au hasard / new random names (--new-names)
#   ./install.sh --sans-widget            sans le panneau / without the panel (--no-widget)
#
# Relancer ce script met tout à jour (membres, langue, noms, agents, règle) sans rien dupliquer.
# Rien n'est envoyé nulle part : il copie des fichiers et modifie, avec sauvegarde, vos réglages
# de Claude. Il ne lit aucun mot de passe ni jeton.
emulate -L zsh
setopt pipe_fail

DEPOT=${0:A:h}
PY=/usr/bin/python3
OSASCRIPT=${YATEAM_TEST_OSASCRIPT:-/usr/bin/osascript}   # tests : fausses fenêtres à réponses écrites d'avance
EQUIPE="$HOME/.claude/equipe"
KIT="$EQUIPE/kit"
AGENTS="$HOME/.claude/agents"
REGLAGES_CODE="$HOME/.claude/settings.json"
CONFIG_APP="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
MANIFESTE="$EQUIPE/installation.json"
SAUVEGARDES="$EQUIPE/sauvegardes/$(date +%Y%m%d-%H%M%S)"
VERSION_YATEAM="2.0.0"
FICHIERS=(mcp_equipe.py noyau.py garde.py mac.py images.py textes.py reglages.py crochet_claude.py
          codex.sh antigravity.sh signaler.sh)
CODES_LANGUES=(en fr de es it ja zh)
MEMBRES=(codex antigravity mac)
typeset -A IA=(codex ChatGPT antigravity Gemini mac Mac)

tout_oui=0
fenetres=0
sans_widget=0
nouveaux_noms=0
langue=""
liste_ia=""
typeset -A nom actif disponible
problemes=()

while (( $# )); do
  case $1 in
    -o|--oui|-y|--yes) tout_oui=1 ;;
    -f|--fenetres|--windows) fenetres=1 ;;
    --sans-widget|--no-widget) sans_widget=1 ;;
    --nouveaux-noms|--new-names) nouveaux_noms=1 ;;
    --langue|--language) shift; langue=${1:-} ;;
    --ia|--ai) shift; liste_ia=${1:-} ;;
    --nom-chatgpt|--chatgpt-name) shift; nom[codex]=${1:-} ;;
    --nom-gemini|--gemini-name) shift; nom[antigravity]=${1:-} ;;
    --nom-mac|--mac-name) shift; nom[mac]=${1:-} ;;
    -h|--aide|--help) sed -n '2,20p' "$DEPOT/install.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "Option ? $1  (./install.sh --help)"; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Fenêtres (osascript) : jamais « System Events » (pas d'autorisation d'automatisation à demander).

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
SCRIPT_SAISIE='on run argv
  tell me to activate
  try
    set r to display dialog (item 1 of argv) default answer (item 2 of argv) buttons {item 3 of argv, item 4 of argv} default button (item 4 of argv) cancel button (item 3 of argv) with title "YaTeam"
    return text returned of r
  on error number -128
    return "§ANNULE§"
  end try
end run'
SCRIPT_LISTE='on run argv
  tell me to activate
  set r to choose from list (items 5 thru -1 of argv) with title "YaTeam" with prompt (item 1 of argv) default items {item 2 of argv} OK button name (item 3 of argv) cancel button name (item 4 of argv)
  if r is false then return "§ANNULE§"
  return item 1 of r
end run'
# fenetre "texte" "bouton1|bouton2" "bouton par défaut" → le bouton choisi (§ANNULE§ si Échap)
fenetre() { "$OSASCRIPT" -e "$SCRIPT_BOUTONS" "$@" 2>/dev/null || print -r -- "§ANNULE§" }
fenetre_saisie() { "$OSASCRIPT" -e "$SCRIPT_SAISIE" "$@" 2>/dev/null || print -r -- "§ANNULE§" }
fenetre_liste() { "$OSASCRIPT" -e "$SCRIPT_LISTE" "$@" 2>/dev/null || print -r -- "§ANNULE§" }

# Python d'Apple absent : il vient avec les outils de ligne de commande, à installer d'abord.
# (Les textes ne sont pas encore lisibles : message court en anglais et en français.)
if [[ $(uname) != Darwin ]]; then print -u2 "YaTeam: macOS only."; exit 1; fi
if ! xcode-select -p >/dev/null 2>&1 || ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
  message="YaTeam needs Apple's Command Line Tools (free). Click « Install », then open « Installer YaTeam » again.

YaTeam a besoin des outils de ligne de commande d'Apple (gratuits). Cliquez « Install », puis rouvrez « Installer YaTeam »."
  print -u2 "$message"
  if (( fenetres )) && [[ $(fenetre "$message" "Cancel|Install" "Install") == Install ]]; then
    xcode-select --install 2>/dev/null
  fi
  exit 1
fi

# Un kit téléchargé porte l'attribut de quarantaine : on le retire du kit (ce script a été ouvert,
# donc autorisé), pour que ses autres fichiers s'ouvrent sans nouvelle alerte de Gatekeeper.
/usr/bin/xattr -dr com.apple.quarantine "$DEPOT" 2>/dev/null

# Textes dans la langue choisie : tableau T et fonction t clé [nom=valeur…].
charger_textes() { eval "$("$PY" -I "$DEPOT/equipe/textes.py" shell "$1")" }
t() {
  local s=${T[$1]-$1} kv
  shift
  for kv in "$@"; do s=${s//"{${kv%%=*}}"/${kv#*=}}; done
  print -r -- "$s"
}
titre() { print; print -P "%B${1//\%/%%}%b" }
info() { print -r -- "   $1" }
alerte() { print -r -- "   ⚠️  $1"; problemes+=("$1") }
conf() { YATEAM_LANGUE=$LANGUE "$PY" -I "$DEPOT/outils/configurer.py" "$@" }
annuler() {
  print -r -- "   $(t inst.f_annule)"
  (( fenetres )) && fenetre "$(t inst.f_annule)" "$(t inst.f_ok)" "$(t inst.f_ok)" >/dev/null
  exit 1
}

# demander "Question ?" → 0 = oui, 1 = non. « t » (ou « a ») accepte tout ce qui suit.
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

# demander_vraiment "Question ?" : pour un conflit (remplacer quelque chose qui n'est pas à YaTeam),
# une fenêtre en mode fenêtres même après l'accord global ; en Terminal, comme demander.
demander_vraiment() {
  if (( fenetres )); then
    print -r -- "▸ $1"
    [[ $(fenetre "$1" "$(t inst.f_non)|$(t inst.f_oui)" "$(t inst.f_non)") == "$(t inst.f_oui)" ]]
    return
  fi
  demander "$1"
}

# saisir "Question" défaut → la réponse (le défaut si Entrée).
saisir() {
  local r=""
  if (( ! tout_oui )); then read -r "r?▸ $1 ($(t inst.entree_defaut valeur="$2")) : " || r=""; fi
  r=$(print -r -- "$r" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  print -r -- "${r:-$2}"
}

# trouver <programme> → chemin absolu (PATH du Terminal, puis dossiers d'installation habituels).
trouver() {
  local p d
  p=$(whence -p "$1" 2>/dev/null) && [[ -n $p ]] && { print -r -- "$p"; return 0 }
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.claude/local"; do
    [[ -x "$d/$1" ]] && { print -r -- "$d/$1"; return 0 }
  done
  return 1
}

version() { "$1" --version 2>/dev/null | head -1 }

# Réglage d'une installation précédente (config.json) : membres.<clé>.<champ>
precedent() {
  [[ -f "$EQUIPE/config.json" ]] || return 1
  "$PY" -I -c '
import json, sys
try:
    m = json.load(open(sys.argv[1]))["membres"][sys.argv[2]]
    v = m[sys.argv[3]]
except Exception:
    sys.exit(1)
print("oui" if v is True else "non" if v is False else v)' "$EQUIPE/config.json" "$1" "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Langue : option, sinon réglage d'une installation précédente, sinon celle du Mac.
[[ -z $langue && -f "$EQUIPE/config.json" ]] && langue=$(conf lire "$EQUIPE/config.json" langue 2>/dev/null)
[[ -z $langue ]] && langue=$("$PY" -I "$DEPOT/equipe/textes.py" langue-du-mac)
(( ${CODES_LANGUES[(Ie)$langue]} )) || langue=en
charger_textes "$langue"

if (( ! tout_oui && ! fenetres )) && [[ ! -t 0 ]]; then
  print -u2 "$(t inst.pas_de_terminal)"
  exit 2
fi

print -P "%B$(t inst.bienvenue)%b"
info "$(t commun.slogan)"
info "$(t inst.non_officiel)"

titre "$(t inst.titre_langue)"
if (( fenetres )); then
  if [[ $(fenetre "$(t inst.f_bienvenue slogan="$(t commun.slogan)" non_officiel="$(t inst.non_officiel)")" \
          "$(t inst.f_annuler)|$(t inst.f_continuer)" "$(t inst.f_continuer)") != "$(t inst.f_continuer)" ]]; then
    annuler
  fi
  typeset -A NOMS_LANGUES=(en English fr Français de Deutsch es Español it Italiano ja 日本語 zh 中文)
  libelles=()
  for code in $CODES_LANGUES; do libelles+=("${NOMS_LANGUES[$code]}"); done
  choix=$(fenetre_liste "$(t inst.f_langue)" "${NOMS_LANGUES[$langue]}" "$(t inst.f_ok)" "$(t inst.f_annuler)" $libelles)
  [[ $choix == "§ANNULE§" ]] && annuler
  for code in $CODES_LANGUES; do [[ ${NOMS_LANGUES[$code]} == "$choix" ]] && langue=$code; done
  info "$choix"
else
  info "en English · fr Français · de Deutsch · es Español · it Italiano · ja 日本語 · zh 中文"
  while true; do
    choix=$(saisir "$(t inst.question_langue)" "$langue")
    if (( ${CODES_LANGUES[(Ie)$choix]} )); then break; fi
    info "?"
    (( tout_oui )) && { choix=$langue; break }
  done
  langue=$choix
fi
charger_textes "$langue"

# ---------------------------------------------------------------------------
titre "$(t inst.titre_prerequis)"
info "✓ python3 : $("$PY" --version 2>&1)"
chemin_claude=$(trouver claude) || chemin_claude=""
chemin_codex=$(trouver codex) || chemin_codex=""
chemin_agy=$(trouver agy) || chemin_agy=""
macos=$(sw_vers -productVersion 2>/dev/null)
typeset -A raison
if [[ -n $chemin_claude ]]; then
  info "✓ Claude Code : $(version "$chemin_claude") ($chemin_claude)"
else
  alerte "$(t inst.claude_absent)"
fi
if [[ -n $chemin_codex ]]; then
  info "✓ Codex CLI : $(version "$chemin_codex") ($chemin_codex)"; disponible[codex]=1
else
  raison[codex]="$(t inst.codex_absent)"; info "– ${raison[codex]}"; disponible[codex]=0
fi
if [[ -n $chemin_agy ]]; then
  info "✓ Antigravity CLI : $(version "$chemin_agy") ($chemin_agy)"; disponible[antigravity]=1
else
  raison[antigravity]="$(t inst.agy_absent)"; info "– ${raison[antigravity]}"; disponible[antigravity]=0
fi
# Le membre Mac : macOS 14 ou plus récent (EventKit), et Swift pour construire son app.
if (( ${macos%%.*} < 14 )); then
  raison[mac]="$(t inst.mac_impossible_systeme version="$macos")"; info "– ${raison[mac]}"; disponible[mac]=0
elif [[ -z ${YATEAM_TEST_MAC:-} ]] && ! xcrun --find swiftc >/dev/null 2>&1; then
  raison[mac]="$(t inst.mac_impossible_swift)"; info "– ${raison[mac]}"; disponible[mac]=0
else
  info "✓ Mac : macOS $macos ($(uname -m))"; disponible[mac]=1
fi
if (( ! disponible[codex] && ! disponible[antigravity] && ! disponible[mac] )); then
  print -u2 "   $(t inst.aucun_membre)"
  (( fenetres )) && fenetre "$(t inst.aucun_membre)" "$(t inst.f_ok)" "$(t inst.f_ok)" >/dev/null
  exit 1
fi

# ---------------------------------------------------------------------------
titre "$(t inst.titre_membres)"
# Membres voulus : option --ia, sinon ceux d'une installation précédente, sinon tout ce qui est disponible.
voulu() {
  local cle=$1
  if [[ -n $liste_ia ]]; then
    local alias_=${${${liste_ia:l}//chatgpt/codex}//gemini/antigravity}
    [[ ",$alias_," == *",$cle,"* ]]
    return
  fi
  local p
  p=$(precedent "$cle" actif) && { [[ $p == oui ]]; return }
  return 0
}
# Noms : options, sinon ceux d'une installation précédente, sinon tirés au hasard.
tirage=("${(@f)$(conf tirer-noms "${nom[codex]}" "${nom[antigravity]}" "${nom[mac]}")}")
i=1
for cle in $MEMBRES; do
  if [[ -z ${nom[$cle]} ]]; then
    (( ! nouveaux_noms )) && nom[$cle]=$(precedent "$cle" nom)
    [[ -z ${nom[$cle]} ]] && nom[$cle]=${tirage[$i]}
  fi
  (( i++ ))
done

typeset -A question=(codex inst.activer_codex antigravity inst.activer_antigravity mac inst.activer_mac)
typeset -A question_f=(codex inst.f_question_codex antigravity inst.f_question_antigravity mac inst.f_question_mac)
while true; do
  for cle in $MEMBRES; do
    actif[$cle]=non
    if (( ! disponible[$cle] )); then
      continue
    fi
    if (( fenetres )); then
      defaut=$( voulu $cle && t inst.f_oui || t inst.f_non )
      r=$(fenetre "$(t ${question_f[$cle]})" "$(t inst.f_non)|$(t inst.f_oui)" "$defaut")
      [[ $r == "§ANNULE§" ]] && annuler
      [[ $r == "$(t inst.f_oui)" ]] && actif[$cle]=oui
    elif (( tout_oui )); then
      voulu $cle && actif[$cle]=oui
    elif demander "$(t ${question[$cle]})"; then
      actif[$cle]=oui
    fi
  done
  if [[ ${actif[codex]} == non && ${actif[antigravity]} == non && ${actif[mac]} == non ]]; then
    print -u2 "   $(t inst.aucun_actif)"
    (( fenetres )) && fenetre "$(t inst.aucun_actif)" "$(t inst.f_ok)" "$(t inst.f_ok)" >/dev/null
    exit 1
  fi
  # Surnoms
  info "$(t inst.noms_explication)"
  if (( fenetres )); then
    liste=""
    for cle in $MEMBRES; do [[ ${actif[$cle]} == oui ]] && liste+="• ${nom[$cle]} (${IA[$cle]})"$'\n'; done
    r=$(fenetre "$(t inst.f_noms liste="${liste%$'\n'}")" "$(t inst.f_changer)|$(t inst.f_garder)" "$(t inst.f_garder)")
    [[ $r == "§ANNULE§" ]] && annuler
    if [[ $r == "$(t inst.f_changer)" ]]; then
      for cle in $MEMBRES; do
        [[ ${actif[$cle]} == oui ]] || continue
        question_nom=$([[ $cle == mac ]] && t inst.f_nom_mac || t inst.f_nom ia="${IA[$cle]}")
        r=$(fenetre_saisie "$question_nom" "${nom[$cle]}" "$(t inst.f_annuler)" "$(t inst.f_ok)")
        [[ $r == "§ANNULE§" ]] && annuler
        r=$(print -r -- "$r" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -n $r ]] && nom[$cle]=$r
      done
    fi
  elif (( ! tout_oui )); then
    for cle in $MEMBRES; do
      [[ ${actif[$cle]} == oui ]] || continue
      question_nom=$([[ $cle == mac ]] && t inst.son_nom_mac || t inst.son_nom ia="${IA[$cle]}")
      nom[$cle]=$(saisir "$question_nom" "${nom[$cle]}")
    done
  fi
  if erreur=$(conf verifier-noms "${nom[codex]}" "${nom[antigravity]}" "${nom[mac]}"); then break; fi
  print -r -- "   ⚠️  $erreur"
  (( fenetres )) && fenetre "$erreur" "$(t inst.f_ok)" "$(t inst.f_ok)" >/dev/null
  (( tout_oui )) && exit 1
done
for cle in $MEMBRES; do
  [[ ${actif[$cle]} == oui ]] && info "${IA[$cle]} : « ${nom[$cle]} »"
done

# Panneau (widget) : seulement si Swift est là.
widget=0
if (( ! sans_widget )) && xcrun --find swift >/dev/null 2>&1; then
  if (( fenetres )); then
    r=$(fenetre "$(t inst.f_widget)" "$(t inst.f_non)|$(t inst.f_oui)" "$(t inst.f_oui)")
    [[ $r == "§ANNULE§" ]] && annuler
    [[ $r == "$(t inst.f_oui)" ]] && widget=1
  else
    widget=1      # la question est posée à l'étape du panneau
  fi
elif (( ! sans_widget )); then
  info "$(t inst.swift_absent)"
fi

# ---------------------------------------------------------------------------
titre "$(t inst.titre_plan)"
etapes=("$(t inst.plan_scripts)")
[[ ${actif[mac]} == oui ]] && etapes+=("$(t inst.plan_mac)")
[[ ${actif[codex]} == oui || ${actif[antigravity]} == oui ]] && etapes+=("$(t inst.plan_agents)")
etapes+=("$(t inst.plan_crochets)" "$(t inst.plan_connecteur)" "$(t inst.plan_regle)")
(( widget )) && etapes+=("$(t inst.plan_widget)")
etapes+=("$(t inst.plan_kit)")
for e in $etapes; do info "• $e"; done
info "$(t inst.sauvegardes dossier="$SAUVEGARDES")"
if (( fenetres )); then
  resume=""
  for e in $etapes; do resume+="• $e"$'\n'; done
  r=$(fenetre "$(t inst.f_resume etapes="${resume%$'\n'}")" "$(t inst.f_annuler)|$(t inst.f_installer)" "$(t inst.f_installer)")
  [[ $r == "$(t inst.f_installer)" ]] || annuler
  info "$(t inst.f_suivez)"
  tout_oui=1     # l'accord est donné une fois pour toutes ; les conflits redemandent (demander_vraiment)
fi

# ---------------------------------------------------------------------------
titre "$(t inst.titre_scripts)"
if demander "$(t inst.question_scripts dossier="$EQUIPE")"; then
  mkdir -p "$EQUIPE" && chmod 700 "$EQUIPE"
  for f in $FICHIERS; do
    if [[ -f "$EQUIPE/$f" ]] && ! cmp -s "$DEPOT/equipe/$f" "$EQUIPE/$f"; then
      if ! { mkdir -p "$SAUVEGARDES/equipe" && chmod 700 "$EQUIPE/sauvegardes" "$SAUVEGARDES" "$SAUVEGARDES/equipe" \
             && cp -p "$EQUIPE/$f" "$SAUVEGARDES/equipe/$f" && chmod 600 "$SAUVEGARDES/equipe/$f"; }; then
        print -u2 "   ⚠️  $(t inst.sauvegarde_impossible fichier="$EQUIPE/$f")"
        exit 1
      fi
      info "$(t inst.ancienne_version fichier="$SAUVEGARDES/equipe/$f")"
    fi
    cp "$DEPOT/equipe/$f" "$EQUIPE/$f" || { print -u2 "   ⚠️  $(t inst.copie_impossible fichier="$f")"; exit 1 }
  done
  # Les traductions sont remplacées en bloc (elles ne contiennent aucun réglage).
  rm -rf "$EQUIPE/langues" && cp -R "$DEPOT/equipe/langues" "$EQUIPE/langues" \
    || { print -u2 "   ⚠️  $(t inst.copie_impossible fichier=langues)"; exit 1 }
  rm -rf "$EQUIPE/__pycache__"
  chmod 700 "$EQUIPE"/{codex,antigravity,signaler}.sh "$EQUIPE/langues"
  chmod 600 "$EQUIPE"/*.py "$EQUIPE"/langues/*.json
  mkdir -p "$EQUIPE/etat/claude" "$EQUIPE/atelier"
  chmod 700 "$EQUIPE/etat" "$EQUIPE/etat/claude" "$EQUIPE/atelier"
  info "$(t inst.scripts_copies)"
  conf ecrire-config "$EQUIPE/config.json" "$SAUVEGARDES" "$langue" "${nom[codex]}" ${actif[codex]} \
       "${nom[antigravity]}" ${actif[antigravity]} "${nom[mac]}" ${actif[mac]} \
       "$chemin_claude" "$chemin_codex" "$chemin_agy" || alerte "$(t inst.echec_reglages)"
  [[ -f "$EQUIPE/config.json" ]] && chmod 600 "$EQUIPE/config.json"
  conf noter "$MANIFESTE" version "\"$VERSION_YATEAM\"" && chmod 600 "$MANIFESTE"
else
  print -r -- "   $(t inst.sans_scripts)"
  exit 1
fi

# ---------------------------------------------------------------------------
# App « YaTeam Mac » : construite sur ce Mac, et seulement si ses sources ont changé (macOS rattache
# les autorisations Rappels et Calendrier à sa signature : une reconstruction les ferait redemander).
if [[ ${actif[mac]} == oui ]]; then
  titre "$(t inst.titre_mac)"
  info "$(t inst.explication_mac)"
  ia=false
  if [[ -n ${YATEAM_TEST_MAC:-} ]]; then          # tests : ni compilation ni fenêtre d'autorisation
    [[ $YATEAM_TEST_MAC == ia ]] && ia=true
  else
    etat_app=$("$DEPOT/mac/construire.sh" "$EQUIPE" 2>&1)
    case $? in
      0) [[ $etat_app == *deja-a-jour* ]] && info "$(t inst.mac_a_jour)" || info "$(t inst.mac_construite app="$EQUIPE/YaTeamMac.app")" ;;
      3) alerte "$(t inst.mac_impossible_swift)" ;;
      *) print -r -- "$etat_app" | tail -5; alerte "$(t inst.mac_echec)" ;;
    esac
    if [[ -d "$EQUIPE/YaTeamMac.app" ]]; then
      sortie=$(mktemp -t yateam-mac)
      /usr/bin/open -W -n -g -a "$EQUIPE/YaTeamMac.app" --args "$sortie" capacites 2>/dev/null
      reponse=$("$PY" -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print("oui" if r.get("apple_intelligence") else "non:" + str(r.get("raison","")))' "$sortie" 2>/dev/null)
      if [[ $reponse == oui ]]; then
        ia=true; info "$(t inst.ia_ok)"
      else
        raison_ia=$(t "mac.raison_${reponse#non:}")
        [[ $raison_ia == mac.raison_* ]] && raison_ia=${reponse#non:}
        info "$(t inst.ia_non raison="$raison_ia")"
      fi
      # Autorisations, au premier plan et annoncées, plutôt qu'à la première demande à Claude.
      info "$(t inst.explication_autorisations)"
      if (( fenetres )); then
        fenetre "$(t inst.explication_autorisations)" "$(t inst.f_continuer)" "$(t inst.f_continuer)" >/dev/null
      elif [[ -t 0 ]]; then
        read -r "?▸ $(t inst.appuyer_entree) " || true
      fi
      : > "$sortie"
      /usr/bin/open -W -n -a "$EQUIPE/YaTeamMac.app" --args "$sortie" autoriser 2>/dev/null
      acces=$("$PY" -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(("R" if r.get("rappels") else "r") + ("C" if r.get("calendrier") else "c") + ("N" if r.get("notes") else "n"))' "$sortie" 2>/dev/null)
      [[ $acces == R* ]] && info "$(t inst.acces_rappels_ok)" || alerte "$(t inst.acces_rappels_non)"
      [[ $acces == ?C? ]] && info "$(t inst.acces_calendrier_ok)" || alerte "$(t inst.acces_calendrier_non)"
      [[ $acces == *N ]] && info "$(t inst.acces_notes_ok)" || alerte "$(t inst.acces_notes_non)"
      rm -f "$sortie"
    fi
  fi
  conf regler "$EQUIPE/config.json" membres.mac.apple_intelligence $ia
fi

# ---------------------------------------------------------------------------
if [[ ${actif[codex]} == oui || ${actif[antigravity]} == oui || -n $(conf lire "$MANIFESTE" agents 2>/dev/null) ]]; then
  titre "$(t inst.titre_agents)"
  if demander "$(t inst.question_agents dossier="$AGENTS")"; then
    conf installer-agents "$EQUIPE/config.json" "$AGENTS" "$SAUVEGARDES" "$MANIFESTE"
    case $? in
      0) ;;
      4) if demander_vraiment "$(t inst.remplacer)"; then
           conf installer-agents "$EQUIPE/config.json" "$AGENTS" "$SAUVEGARDES" "$MANIFESTE" remplacer \
             || alerte "$(t inst.echec_agents)"
         else
           alerte "$(t inst.echec_agents_noms)"
         fi ;;
      *) alerte "$(t inst.echec_agents)" ;;
    esac
  fi
fi

titre "$(t inst.titre_crochets)"
info "$(t inst.explication_crochets)"
if demander "$(t inst.question_crochets fichier="$REGLAGES_CODE")"; then
  conf ajouter-crochets "$REGLAGES_CODE" "$SAUVEGARDES" "$HOME" && conf noter "$MANIFESTE" crochets true \
    || alerte "$(t inst.echec_crochets)"
fi

titre "$(t inst.titre_connecteur)"
info "$(t inst.explication_connecteur)"
if [[ ! -d /Applications/Claude.app && ! -d "$HOME/Applications/Claude.app" && ! -d ${CONFIG_APP:h} ]]; then
  info "$(t inst.app_absente)"
fi
if demander "$(t inst.question_connecteur)"; then
  # 1. L'app Claude (Chat, Cowork, onglet Code)
  conf ajouter-connecteur "$CONFIG_APP" "$SAUVEGARDES" "$HOME"
  case $? in
    0) conf noter "$MANIFESTE" connecteur true ;;
    4) if demander_vraiment "$(t inst.remplacer_connecteur)"; then
         conf ajouter-connecteur "$CONFIG_APP" "$SAUVEGARDES" "$HOME" remplacer && conf noter "$MANIFESTE" connecteur true \
           || alerte "$(t inst.echec_connecteur)"
       else
         alerte "$(t inst.echec_connecteur)"
       fi ;;
    *) alerte "$(t inst.echec_connecteur)" ;;
  esac
  # 2. Claude Code dans le Terminal (qui ne lit pas la configuration de l'app), par sa propre commande.
  if [[ -n $chemin_claude ]]; then
    existant=$("$chemin_claude" mcp get equipe 2>/dev/null)
    ajouter_code=0
    if [[ -z $existant ]]; then
      ajouter_code=1
    elif [[ $existant != *"/.claude/equipe/mcp_equipe.py"* ]]; then
      if demander_vraiment "$(t inst.remplacer_connecteur_code)"; then
        "$chemin_claude" mcp remove -s user equipe >/dev/null 2>&1 && ajouter_code=1 || alerte "$(t inst.echec_connecteur_code)"
      else
        alerte "$(t inst.echec_connecteur_code)"
      fi
    else
      info "$(t inst.connecteur_code_deja)"
      conf noter "$MANIFESTE" connecteur_code true
    fi
    if (( ajouter_code )); then
      if "$chemin_claude" mcp add -s user equipe -- "$PY" -I "$EQUIPE/mcp_equipe.py" >/dev/null 2>&1; then
        info "$(t inst.connecteur_code_ajoute)"
        conf noter "$MANIFESTE" connecteur_code true
      else
        alerte "$(t inst.echec_connecteur_code)"
      fi
    fi
  fi
fi

titre "$(t inst.titre_regle)"
info "$(t inst.explication_regle)"
if demander "$(t inst.question_regle fichier="$CLAUDE_MD")"; then
  conf ajouter-regle "$CLAUDE_MD" "$SAUVEGARDES" "$EQUIPE/config.json" "$MANIFESTE" || alerte "$(t inst.echec_regle)"
fi

app_widget=""
if [[ -w /Applications ]]; then app_widget="/Applications/YaTeam.app"; else app_widget="$HOME/Applications/YaTeam.app"; fi
if (( widget )); then
  titre "$(t inst.titre_widget)"
  info "$(t inst.explication_widget)"
  if demander "$(t inst.question_widget)"; then
    if "$DEPOT/widget/outils/construire.sh" --installer; then
      conf noter "$MANIFESTE" widget "$("$PY" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$app_widget")"
    else
      alerte "$(t inst.echec_widget)"
    fi
  fi
fi
# Un panneau déjà ouvert relit la langue et les membres à son démarrage : on le relance.
if (( ! sans_widget )) && pgrep -x "YaTeam" >/dev/null 2>&1 && [[ -d $app_widget ]]; then
  pkill -x "YaTeam"; sleep 1; open "$app_widget"
fi

# ---------------------------------------------------------------------------
# Copie du kit dans ~/.claude/equipe/kit : le panneau (« Modifier l'équipe… ») et les fichiers
# « Modifier YaTeam » / « Désinstaller YaTeam » s'en servent, même si le téléchargement a été effacé.
titre "$(t inst.titre_kit)"
if [[ ${DEPOT:A} == ${KIT:A} ]]; then
  info "$(t inst.kit_deja)"
elif ! { mkdir -p "$KIT" && /usr/bin/rsync -a --delete --exclude .git --exclude docs --exclude '.build' \
          --exclude build --exclude '*.command' --exclude '__pycache__' "$DEPOT/" "$KIT/"; }; then
  alerte "$(t inst.echec_kit)"
fi
if [[ -f "$KIT/install.sh" ]]; then
  # Fichiers à double-cliquer, au nom traduit (recréés à chaque fois : la langue a pu changer).
  for ancien in "$KIT"/*.command(N); do
    grep -q 'exec ./\(install\|desinstaller\).sh --fenetres' "$ancien" 2>/dev/null && rm -f "$ancien"
  done
  fichier_modifier="$KIT/$(t inst.fichier_modifier).command"
  fichier_desinstaller="$KIT/$(t inst.fichier_desinstaller).command"
  printf '#!/bin/zsh\n# %s\ncd "${0:A:h}" && exec ./install.sh --fenetres\n' "$(t inst.fichier_modifier)" > "$fichier_modifier"
  printf '#!/bin/zsh\n# %s\ncd "${0:A:h}" && exec ./desinstaller.sh --fenetres\n' "$(t inst.fichier_desinstaller)" > "$fichier_desinstaller"
  chmod 755 "$fichier_modifier" "$fichier_desinstaller"
  conf noter "$MANIFESTE" kit "$("$PY" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$KIT")"
  info "$(t inst.kit_copie dossier="$KIT")"
fi

# ---------------------------------------------------------------------------
titre "$(t inst.titre_fin)"
if (( ${#problemes} )); then
  info "$(t inst.a_revoir)"
  for p in $problemes; do info "• $p"; done
fi
suite=("$(t inst.fin_app)")
[[ -n $chemin_claude ]] && suite+=("$(t inst.fin_code)")
[[ ${actif[codex]} == oui ]] && suite+=("$(t inst.fin_codex)")
[[ ${actif[antigravity]} == oui ]] && suite+=("$(t inst.fin_agy)")
for cle in antigravity codex mac; do
  if [[ ${actif[$cle]} == oui ]]; then
    suite+=("$(t inst.fin_exemple_$cle nom="${nom[$cle]}")")
    break
  fi
done
suite+=("$(t inst.fin_modifier)")
info "$(t inst.pour_commencer)"
for s in $suite; do info "• $s"; done
[[ -d $SAUVEGARDES ]] && info "$(t inst.fin_sauvegardes dossier="$SAUVEGARDES")"
if (( fenetres )); then
  texte_fin=""
  for s in $suite; do texte_fin+="• $s"$'\n'; done
  if (( ${#problemes} )); then
    texte_fin+=$'\n'"$(t inst.a_revoir)"$'\n'
    for p in $problemes; do texte_fin+="• $p"$'\n'; done
  fi
  fenetre "$(t inst.f_fin suite="${texte_fin%$'\n'}")" "$(t inst.f_ok)" "$(t inst.f_ok)" >/dev/null
fi
exit 0
