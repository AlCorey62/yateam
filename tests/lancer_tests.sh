#!/bin/zsh
# Tests de YaTeam, sans rien toucher à votre vrai dossier personnel ni consommer de quota :
# HOME pointe vers un dossier temporaire et de faux programmes (tests/faux) remplacent
# codex, agy, claude, l'app YaTeam Mac et les fenêtres (osascript) : aucune
# compilation, aucune demande d'autorisation, rien dans les vrais Rappels ni Calendrier.
# Teste l'installation (Terminal et fenêtres), la réinstallation avec d'autres membres et noms,
# le connecteur MCP, le membre Mac, le crochet de Claude Code, les traductions et la désinstallation.
#
#   ./tests/lancer_tests.sh
emulate -L zsh
DEPOT=${0:A:h:h}
PY=/usr/bin/python3
TEMP=$(mktemp -d -t yateam-tests)
export HOME="$TEMP/maison"
export PATH="$DEPOT/tests/faux:/usr/bin:/bin:/usr/sbin:/sbin"
unset CODEX_HOME
export YATEAM_TEST_MAC=ia                                   # pas de compilation ni d'autorisation
export YATEAM_TEST_OUTIL_MAC="$DEPOT/tests/faux/yateammac"    # faux YaTeamMac.app
export YATEAM_TEST_OSASCRIPT="$DEPOT/tests/faux/osascript"  # fausses fenêtres
export YATEAM_TEST_REPONSES="$TEMP/reponses-fenetres.txt" YATEAM_TEST_FENETRES_JOURNAL="$TEMP/fenetres.log"
echecs=0

ok() { print -r -- "  ✓ $1" }
ko() { print -r -- "  ✗ $1"; (( echecs++ )) }
verifier() { if eval "$1"; then ok "$2"; else ko "$2"; fi }
# Assertion Python sur les fichiers du faux dossier personnel.
py() { "$PY" -I -c "import json, os, sys; H = os.path.expanduser('~'); $1" }

mkdir -p "$HOME/.claude" "$HOME/Library/Application Support/Claude"
cat > "$HOME/.claude/settings.json" <<'JSON'
{"theme": "dark", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo crochet-existant"}]}]}}
JSON
cat > "$HOME/Library/Application Support/Claude/claude_desktop_config.json" <<'JSON'
{"mcpServers": {"autre": {"command": "/bin/echo"}}, "preferences": {"x": 1}}
JSON
print -n "# Mes règles\n\nNe rien casser.\n" > "$HOME/.claude/CLAUDE.md"
cp "$HOME/.claude/settings.json" "$TEMP/settings.origine"
cp "$HOME/Library/Application Support/Claude/claude_desktop_config.json" "$TEMP/app.origine"
cp "$HOME/.claude/CLAUDE.md" "$TEMP/claude-md.origine"

print "Dossier de test : $TEMP"
print; print "0. Traductions"
"$PY" -I "$DEPOT/tests/test_textes.py" || (( echecs++ ))

print; print "1. Installation (en français, ChatGPT et Gemini, noms Pesto et Nori)"
"$DEPOT/install.sh" --oui --sans-widget --langue fr --ia chatgpt,gemini --nom-chatgpt Pesto --nom-gemini Nori \
  > "$TEMP/installation-1.log" 2>&1; code=$?
verifier '[[ $code -eq 0 ]]' "install.sh se termine sans erreur"
verifier '[[ $(stat -f %Lp "$HOME/.claude/equipe") == 700 ]]' "~/.claude/equipe est privé (700)"
verifier '[[ $(stat -f %Lp "$HOME/.claude/equipe/config.json") == 600 ]]' "config.json en 600"
verifier '[[ -f "$HOME/.claude/agents/pesto.md" && -f "$HOME/.claude/agents/nori.md" ]]' "agents pesto et nori installés"
verifier 'py "s = json.load(open(H + \"/.claude/settings.json\")); h = s[\"hooks\"]; assert len(h) == 11; assert sum(\"crochet_claude.py\" in str(g) for g in h[\"Stop\"]) == 1; assert \"crochet-existant\" in str(h[\"Stop\"]); assert s[\"theme\"] == \"dark\""' \
  "11 crochets ajoutés, le crochet existant et le thème sont gardés"
verifier 'py "c = json.load(open(H + \"/Library/Application Support/Claude/claude_desktop_config.json\")); assert c[\"mcpServers\"][\"equipe\"][\"args\"][1] == H + \"/.claude/equipe/mcp_equipe.py\"; assert \"autre\" in c[\"mcpServers\"] and c[\"preferences\"] == {\"x\": 1}"' \
  "connecteur ajouté, l'autre connecteur et les préférences sont gardés"
verifier 'py "t = open(H + \"/.claude/CLAUDE.md\").read(); assert t.startswith(\"# Mes règles\"); assert t.count(\"yateam:debut\") == 1 and \"confier_a_pesto\" in t and \"Qui fait quoi\" in t"' \
  "règle ajoutée à la fin de CLAUDE.md"
verifier 'py "c = json.load(open(H + \"/.claude/equipe/config.json\")); assert c[\"programmes\"][\"codex\"].endswith(\"tests/faux/codex\")"' \
  "chemins des programmes relevés (ici les faux)"
verifier 'py "c = json.load(open(H + \"/.claude/equipe/config.json\")); assert c[\"version\"] == 2 and c[\"membres\"][\"mac\"][\"actif\"] is False"' \
  "config version 2, le Mac non choisi reste éteint"
verifier 'py "s = json.load(open(H + \"/.faux-claude-mcp.json\")); assert s[\"equipe\"][-1] == H + \"/.claude/equipe/mcp_equipe.py\""' \
  "connecteur ajouté aussi à Claude Code (claude mcp add -s user)"
verifier '[[ -f "$HOME/.claude/equipe/kit/install.sh" && -x "$HOME/.claude/equipe/kit/Modifier YaTeam.command" && -x "$HOME/.claude/equipe/kit/Désinstaller YaTeam.command" && ! -e "$HOME/.claude/equipe/kit/.git" ]]' \
  "kit copié, avec « Modifier YaTeam » et « Désinstaller YaTeam »"
verifier '[[ -n $(ls "$HOME/.claude/equipe/sauvegardes"/*/settings.json 2>/dev/null) ]]' "settings.json sauvegardé avant modification"
verifier '[[ $(stat -f %Lp "$(ls -d "$HOME/.claude/equipe/sauvegardes"/*/settings.json | head -1)") == 600 ]]' "sauvegarde en 600"

print; print "2. Connecteur MCP (faux client stdio)"
"$PY" -I "$DEPOT/tests/test_connecteur.py" complet || (( echecs++ ))

print; print "3. Crochet de Claude Code"
crochet() { print -r -- "$1" | "$PY" -I "$HOME/.claude/equipe/crochet_claude.py" }
etat="$HOME/.claude/equipe/etat/claude/session-test.json"
crochet '{"session_id": "session-test", "hook_event_name": "UserPromptSubmit", "cwd": "/tmp"}'
verifier 'py "assert json.load(open(\"$etat\"))[\"au_travail\"] is True"' "demande envoyée → au travail"
crochet '{"session_id": "session-test", "hook_event_name": "PermissionRequest", "cwd": "/tmp"}'
verifier 'py "e = json.load(open(\"$etat\")); assert e[\"en_attente\"] is True and e[\"au_travail\"] is False"' "autorisation demandée → attend votre réponse"
crochet '{"session_id": "session-test", "hook_event_name": "Stop", "cwd": "/tmp"}'
verifier 'py "assert json.load(open(\"$etat\"))[\"au_travail\"] is False"' "fin de réponse → libre"
crochet '{"session_id": "session-test", "hook_event_name": "SubagentStop", "agent_id": "interne", "cwd": "/tmp"}'
verifier 'py "assert json.load(open(\"$etat\"))[\"au_travail\"] is False"' "sous-agent interne jamais annoncé → ignoré"
crochet '{"session_id": "session-test", "hook_event_name": "SubagentStart", "agent_id": "a1", "cwd": "/tmp"}'
crochet '{"session_id": "session-test", "hook_event_name": "Stop", "cwd": "/tmp"}'
verifier 'py "assert json.load(open(\"$etat\"))[\"au_travail\"] is True"' "sous-agent lancé : encore au travail après la fin de réponse"
crochet '{"session_id": "session-test", "hook_event_name": "SubagentStop", "agent_id": "a1", "cwd": "/tmp"}'
verifier 'py "assert json.load(open(\"$etat\"))[\"au_travail\"] is False"' "sous-agent terminé → libre"
crochet '{"session_id": "../evasion", "hook_event_name": "UserPromptSubmit", "cwd": "/tmp"}'
verifier '[[ ! -e "$HOME/.claude/equipe/etat/evasion.json" ]]' "identifiant de session piégé ignoré"
crochet 'pas du JSON'; code=$?
verifier '[[ $code -eq 0 ]]' "entrée illisible ignorée sans erreur"
crochet '{"session_id": "session-test", "hook_event_name": "SessionEnd", "cwd": "/tmp"}'
verifier '[[ ! -e $etat ]]' "fin de session → état supprimé"

print; print "3b. Membre Mac (ajouté en relançant l'installation)"
"$DEPOT/install.sh" --oui --sans-widget --ia chatgpt,gemini,mac --nom-mac Mango > "$TEMP/installation-mac.log" 2>&1; code=$?
verifier '[[ $code -eq 0 ]]' "install.sh avec le Mac sans erreur"
verifier 'py "m = json.load(open(H + \"/.claude/equipe/config.json\"))[\"membres\"]; assert m[\"mac\"] == {\"nom\": \"Mango\", \"actif\": True, \"apple_intelligence\": True}, m; assert m[\"codex\"][\"nom\"] == \"Pesto\""' \
  "Mac actif (Mango, Apple Intelligence), noms des autres gardés"
verifier 'py "t = open(H + \"/.claude/CLAUDE.md\").read(); assert \"## Le Mac (Mango)\" in t and \"confier_a_mango\" in t and t.count(\"yateam:debut\") == 1"' \
  "règle de CLAUDE.md : section du Mac"
verifier '[[ ! -e "$HOME/.claude/agents/mango.md" ]]' "pas d'agent Claude Code pour le Mac (connecteur seulement)"
"$PY" -I "$DEPOT/tests/test_connecteur.py" mac Mango || (( echecs++ ))

print; print "3c. Le Mac seul"
"$DEPOT/install.sh" --oui --sans-widget --ia mac > "$TEMP/installation-mac-seul.log" 2>&1; code=$?
verifier '[[ $code -eq 0 ]]' "install.sh avec le Mac seul sans erreur"
verifier '[[ ! -e "$HOME/.claude/agents/pesto.md" && ! -e "$HOME/.claude/agents/nori.md" ]]' "agents des chargés de projet retirés"
verifier 'py "t = open(H + \"/.claude/CLAUDE.md\").read(); assert \"aidé par le Mac (Mango)\" in t and \"Qui fait quoi\" not in t and t.count(\"yateam:debut\") == 1"' \
  "règle courte du Mac seul dans CLAUDE.md"
"$PY" -I "$DEPOT/tests/test_connecteur.py" outils confier_a_mango mac_ajouter_rappels \
  mac_calendrier mac_cocher_rappels mac_lire_journal mac_lire_rappels mac_note mac_ouvrir_app quotas_equipe || (( echecs++ ))
"$DEPOT/install.sh" --oui --sans-widget --ia chatgpt,gemini,mac > /dev/null 2>&1

print; print "4. Réinstallation avec d'autres noms (Léa, Milo)"
"$DEPOT/install.sh" --oui --sans-widget --nom-chatgpt "Léa" --nom-gemini "Milo" > "$TEMP/installation-2.log" 2>&1; code=$?
verifier 'py "assert json.load(open(H + \"/.claude/equipe/config.json\"))[\"langue\"] == \"fr\""' "la langue choisie avant est gardée"
verifier '[[ $code -eq 0 ]]' "install.sh relancé sans erreur"
verifier '[[ -f "$HOME/.claude/agents/lea.md" && -f "$HOME/.claude/agents/milo.md" && ! -e "$HOME/.claude/agents/pesto.md" && ! -e "$HOME/.claude/agents/nori.md" ]]' \
  "agents renommés, anciens retirés"
verifier 'grep -q "confier_a_lea" "$HOME/.claude/agents/lea.md"' "l'agent cite le bon outil (confier_a_lea)"
verifier 'py "s = json.load(open(H + \"/.claude/settings.json\")); assert all(sum(\"crochet_claude.py\" in str(g) for g in v) == 1 for v in s[\"hooks\"].values() if any(\"crochet_claude.py\" in str(g) for g in v))"' \
  "aucun crochet en double"
verifier 'py "t = open(H + \"/.claude/CLAUDE.md\").read(); assert t.count(\"yateam:debut\") == 1 and \"Léa\" in t and \"Pesto\" not in t"' \
  "règle mise à jour, pas dupliquée"
OUTILS_MAC=(confier_a_mango mac_ajouter_rappels mac_calendrier mac_cocher_rappels mac_lire_journal mac_lire_rappels mac_note mac_ouvrir_app)
"$PY" -I "$DEPOT/tests/test_connecteur.py" outils attendre_reponse confier_a_lea confier_a_milo faire_une_image quotas_equipe $OUTILS_MAC || (( echecs++ ))

print; print "5. Un seul chargé de projet (Gemini désactivé)"
"$PY" -I -c "
import json, os
c = os.path.expanduser('~/.claude/equipe/config.json')
d = json.load(open(c)); d['membres']['antigravity']['actif'] = False
json.dump(d, open(c, 'w'))"
"$PY" -I "$DEPOT/tests/test_connecteur.py" outils attendre_reponse confier_a_lea faire_une_image quotas_equipe $OUTILS_MAC || (( echecs++ ))
"$PY" -I -c "
import json, os
c = os.path.expanduser('~/.claude/equipe/config.json')
d = json.load(open(c)); d['membres']['antigravity']['actif'] = True
json.dump(d, open(c, 'w'))"

print; print "6. Changement de langue (allemand)"
"$DEPOT/install.sh" --oui --sans-widget --langue de > "$TEMP/installation-de.log" 2>&1; code=$?
verifier '[[ $code -eq 0 ]] && grep -q "Installation" "$TEMP/installation-de.log"' "install.sh en allemand"
verifier 'py "assert json.load(open(H + \"/.claude/equipe/config.json\"))[\"langue\"] == \"de\""' "langue « de » enregistrée"
verifier 'py "t = open(H + \"/.claude/CLAUDE.md\").read(); assert t.count(\"yateam:debut\") == 1 and \"Wer macht was\" in t and \"Qui fait quoi\" not in t"' \
  "règle de CLAUDE.md passée en allemand, sans doublon"
verifier 'grep -q "Teammitglied" "$HOME/.claude/agents/lea.md"' "agent en allemand"
"$PY" -I "$DEPOT/tests/test_connecteur.py" langue "Projektleiter" "Leerer Auftrag" || (( echecs++ ))
"$DEPOT/install.sh" --oui --sans-widget --langue fr > /dev/null 2>&1

print; print "7. Noms tirés au hasard (nouvelle installation)"
HOME_PRINCIPAL=$HOME
export HOME="$TEMP/maison-2"
mkdir -p "$HOME/.claude"
"$DEPOT/install.sh" --oui --sans-widget --langue en > "$TEMP/installation-hasard.log" 2>&1; code=$?
verifier '[[ $code -eq 0 ]]' "install.sh sans noms se termine sans erreur"
verifier 'py "
c = json.load(open(H + \"/.claude/equipe/config.json\"))
noms = [l.strip() for l in open(\"$DEPOT/outils/noms.txt\") if l.strip() and not l.startswith(\"#\")]
a, b, m = c[\"membres\"][\"codex\"][\"nom\"], c[\"membres\"][\"antigravity\"][\"nom\"], c[\"membres\"][\"mac\"][\"nom\"]
assert a in noms and b in noms and m in noms and len({a, b, m}) == 3, (a, b, m)
assert os.path.exists(H + \"/.claude/agents/%s.md\" % a.lower()) and os.path.exists(H + \"/.claude/agents/%s.md\" % b.lower())
assert \"confier_a_%s\" % a.lower() in open(H + \"/.claude/CLAUDE.md\").read()
"' "trois noms différents tirés dans la liste, propagés aux agents et à la règle"
avant=$(cat "$HOME/.claude/equipe/config.json")
"$DEPOT/install.sh" --oui --sans-widget > /dev/null 2>&1
verifier '[[ $(cat "$HOME/.claude/equipe/config.json") == "$avant" ]]' "une réinstallation garde les noms tirés"
"$DEPOT/install.sh" --oui --sans-widget --nouveaux-noms > /dev/null 2>&1
verifier 'py "assert json.load(open(H + \"/.claude/equipe/config.json\"))[\"langue\"] == \"en\""' "--nouveaux-noms garde la langue"
verifier '( for i in {1..60}; do n=$("$PY" -I "$DEPOT/outils/configurer.py" tirer-noms Bagel); [[ $n != *Bagel* ]] || exit 1; done )' \
  "le tirage n'attribue jamais un nom déjà choisi (--chatgpt-name Bagel)"

print; print "7b. Installation par double-clic (fenêtres simulées)"
export HOME="$TEMP/maison-3"
mkdir -p "$HOME/.claude"
print -l "Annuler" > "$YATEAM_TEST_REPONSES"
"$DEPOT/install.sh" --fenetres --sans-widget > "$TEMP/installation-fenetres-annulee.log" 2>&1; code=$?
verifier '[[ $code -ne 0 && ! -e "$HOME/.claude/equipe" ]]' "« Annuler » à l'accueil : rien n'est créé"
print -l "Continuer" "Français" "Oui" "Non" "Oui" "Changer…" "Bagel" "Mango" "Installer" "OK" > "$YATEAM_TEST_REPONSES"
"$DEPOT/install.sh" --fenetres --sans-widget > "$TEMP/installation-fenetres.log" 2>&1; code=$?
verifier '[[ $code -eq 0 ]]' "installation par fenêtres sans erreur, sans Terminal interactif"
verifier 'py "c = json.load(open(H + \"/.claude/equipe/config.json\")); m = c[\"membres\"]; assert c[\"langue\"] == \"fr\" and m[\"codex\"][\"actif\"] and m[\"codex\"][\"nom\"] == \"Bagel\" and not m[\"antigravity\"][\"actif\"] and m[\"mac\"][\"actif\"] and m[\"mac\"][\"nom\"] == \"Mango\", c"' \
  "choix des fenêtres appliqués (ChatGPT « Bagel », pas Gemini, Mac « Mango »)"
verifier '[[ ! -s "$YATEAM_TEST_REPONSES" ]] && grep -q "YaTeam est installé" "$YATEAM_TEST_FENETRES_JOURNAL"' "toutes les fenêtres posées, dans l'ordre, jusqu'au message final"
print -l "Désinstaller" "OK" > "$YATEAM_TEST_REPONSES"
"$HOME/.claude/equipe/kit/Désinstaller YaTeam.command" > "$TEMP/desinstallation-fenetres.log" 2>&1; code=$?
verifier '[[ $code -eq 0 && ! -e "$HOME/.claude/equipe" ]]' "« Désinstaller YaTeam » (copie du kit) : tout retiré après une seule confirmation"
export HOME=$HOME_PRINCIPAL

print; print "8. Fichier de réglages illisible : jamais écrasé"
cp "$HOME/.claude/settings.json" "$TEMP/settings.avant"
print -n '{"hooks": {,}' > "$HOME/.claude/settings.json"
"$DEPOT/install.sh" --oui --sans-widget > "$TEMP/installation-3.log" 2>&1
verifier '[[ $(cat "$HOME/.claude/settings.json") == "{\"hooks\": {,}" ]]' "settings.json invalide laissé tel quel"
verifier 'grep -q "crochets non ajoutés" "$TEMP/installation-3.log"' "le problème est signalé à la fin"
cp "$TEMP/settings.avant" "$HOME/.claude/settings.json"

print; print "9. Désinstallation"
"$DEPOT/desinstaller.sh" --oui > "$TEMP/desinstallation.log" 2>&1; code=$?
verifier '[[ $code -eq 0 ]]' "desinstaller.sh se termine sans erreur"
verifier 'py "assert json.load(open(H + \"/.claude/settings.json\")) == json.load(open(\"$TEMP/settings.origine\"))"' \
  "settings.json revenu à l'identique"
verifier 'py "assert json.load(open(H + \"/Library/Application Support/Claude/claude_desktop_config.json\")) == json.load(open(\"$TEMP/app.origine\"))"' \
  "config de l'app Claude revenue à l'identique"
verifier 'cmp -s "$HOME/.claude/CLAUDE.md" "$TEMP/claude-md.origine"' "CLAUDE.md revenu à l'identique"
verifier '[[ -z $(ls "$HOME/.claude/agents" 2>/dev/null) ]]' "agents retirés"
verifier 'py "assert \"equipe\" not in json.load(open(H + \"/.faux-claude-mcp.json\"))"' "connecteur retiré de Claude Code"
verifier '[[ ! -e "$HOME/.claude/equipe" && -n $(ls -d "$HOME/.Trash/equipe "* 2>/dev/null) ]]' "~/.claude/equipe mis à la Corbeille"

print
if (( echecs )); then
  print "❌ $echecs échec(s). Journaux : $TEMP"
  exit 1
fi
print "✅ Tous les tests sont passés."
rm -rf "$TEMP"
