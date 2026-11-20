#!/bin/zsh
# Chargé de projet Gemini, via l'Antigravity CLI officiel de Google
# (Gemini CLI n'accepte plus les comptes particuliers depuis juin 2026).
# Usage : antigravity.sh [dossier_de_travail] < consigne
# Lit la consigne sur l'entrée standard, travaille dans le dossier indiqué et n'affiche
# que sa réponse finale (messages dans la langue choisie).
# Lecture seule : en mode non interactif (-p), Antigravity refuse de lui-même toute action
# qui demande une autorisation (écriture, commande…) et --sandbox restreint son terminal.
# Le tour s'arrêterait alors sans réponse : d'où le préambule, qui lui demande de rendre
# le contenu au lieu d'écrire. (Le mode « plan » ne convient pas : il rédige un plan et s'arrête.)
# Jamais de --dangerously-skip-permissions.
# Images : generate_image les range dans ~/.gemini/antigravity-cli/brain/<conversation>/ ;
# le script les signale en fin de réponse par des lignes « [[image]] <chemin> »
# (c'est Claude, ou le connecteur sur son ordre, qui les range au bon endroit).
# Garde du navigateur : quand la connexion Google est à refaire, agy lance « open <page de
# connexion> ». agy tourne donc avec un faux « open » en tête du PATH (le même que le connecteur
# et le widget, à l'octet près), qui note la demande au lieu d'ouvrir une page ; dès qu'il est
# appelé, agy est arrêté et le script le dit clairement. Aucune page ne s'ouvre jamais.
emulate -L zsh
zmodload zsh/datetime
EQUIPE="$HOME/.claude/equipe"
PY=/usr/bin/python3
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
texte() { "$PY" -I "$EQUIPE/textes.py" texte "$@" 2>/dev/null || print -r -- "$1" }
dossier="${1:-$PWD}"
cd "$dossier" 2>/dev/null || { print -r -- "⚠️ $(texte script.dossier_introuvable dossier="$dossier")"; exit 1 }
nom=$("$PY" -I "$EQUIPE/reglages.py" nom antigravity 2>/dev/null || print Praline)
programme=$("$PY" -I "$EQUIPE/reglages.py" programme agy 2>/dev/null || print agy)
command -v "$programme" >/dev/null 2>&1 || { print -r -- "⚠️ $(texte commun.absent_antigravity nom="$nom")"; exit 1 }
consigne=$(cat)
[[ -n "${consigne//[[:space:]]/}" ]] || { print -r -- "⚠️ $(texte script.consigne_vide)"; exit 1 }
preambule="$(texte script.preambule nom="$nom")

--- TASK ---
"

garde="$EQUIPE/garde"
signal_navigateur="$garde/navigateur-demande.log"
script_garde="#!/bin/sh
# YaTeam: an automatic check never opens the browser.
echo \"\$(date '+%Y-%m-%d %H:%M:%S') open request blocked\" >> \"$signal_navigateur\"
exit 0"
# Chemin écrit entre guillemets dans le script : un caractère qui les casserait annule la garde.
[[ $signal_navigateur == *[\"\$\`\\]* ]] && { print -r -- "⚠️ $(texte script.garde_impossible nom="$nom")"; exit 1 }
mkdir -p "$garde/bin" 2>/dev/null
for faux in open xdg-open; do
  [[ "$(cat "$garde/bin/$faux" 2>/dev/null)" == "$script_garde" ]] || print -r -- "$script_garde" > "$garde/bin/$faux"
  chmod 755 "$garde/bin/$faux" 2>/dev/null
done
[[ -x "$garde/bin/open" ]] || { print -r -- "⚠️ $(texte script.garde_impossible nom="$nom")"; exit 1 }
reconnexion="⚠️ $(texte script.reconnexion nom="$nom")"

resultat=$(mktemp -t equipe-antigravity)
journal=$(mktemp -t equipe-antigravity-journal)
chmod 600 "$resultat" "$journal"
pid_agy=""
"$EQUIPE/signaler.sh" antigravity debut "$consigne" $$ >/dev/null 2>&1
trap '[[ -n $pid_agy ]] && kill $pid_agy 2>/dev/null; rm -f "$resultat" "$journal"; "$EQUIPE/signaler.sh" antigravity fin $$ >/dev/null 2>&1' EXIT
trap 'exit 143' INT TERM   # arrêt forcé (fermeture de l'app) : passe quand même par la fin ci-dessus

# Dates précises : un signal laissé dans la même seconde par un autre relevé n'est pas pris pour le
# nôtre. Fichier absent ou supprimé entre-temps : date 0.
debut=$EPOCHREALTIME
signal_recent() { (( ${$(stat -f %Fm "$signal_navigateur" 2>/dev/null):-0} >= debut )) }
arreter_agy() {   # SIGTERM, puis SIGKILL au bout de 5 s si agy traîne
  kill $pid_agy 2>/dev/null
  for i in {1..10}; do kill -0 $pid_agy 2>/dev/null || break; sleep 0.5; done
  kill -9 $pid_agy 2>/dev/null
  wait $pid_agy 2>/dev/null
  pid_agy=""
}
PATH="$garde/bin:$PATH" "$programme" --sandbox --disable-slash-commands --print-timeout 600s \
    --output-format json -p "$preambule$consigne" >"$resultat" 2>"$journal" &
pid_agy=$!
while kill -0 $pid_agy 2>/dev/null; do
  if signal_recent; then
    arreter_agy
    print -r -- "$reconnexion"
    exit 1
  fi
  sleep 1
done
wait $pid_agy
code=$?
pid_agy=""
if signal_recent || grep -qiE "authentication (required|failed)|log ?in, then retry" "$resultat" "$journal" 2>/dev/null; then
  print -r -- "$reconnexion"
  exit 1
fi

"$PY" -I - "$resultat" "$journal" "$code" "$nom" "$EQUIPE" <<'PY'
import json, os, re, sys
chemin, journal, code, nom, equipe = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
sys.path.insert(0, equipe)
from textes import Textes
t = Textes()
try:
    with open(chemin, encoding="utf-8") as f:
        r = json.load(f)
    if not isinstance(r, dict):
        raise ValueError
except Exception:
    print("⚠️ " + t("script.echec_antigravity", nom=nom, code=code))
    with open(journal, encoding="utf-8", errors="replace") as f:
        print("".join(f.readlines()[-20:]))
    sys.exit(1)
reponse = (r.get("response") or "").strip()
refus = [a.get("display_name") or a.get("action") for a in r.get("denied_actions") or [] if isinstance(a, dict)]
images = []
conversation = str(r.get("conversation_id") or "")
cerveau = os.path.expanduser("~/.gemini/antigravity-cli/brain/%s" % conversation)
if conversation and "/" not in conversation and not conversation.startswith(".") and os.path.isdir(cerveau):
    for racine, _, noms in os.walk(cerveau):
        images += [os.path.join(racine, n) for n in sorted(noms)
                   if n.lower().endswith((".png", ".jpg", ".jpeg", ".webp"))]
if reponse:
    print(reponse)
if refus:
    print("\n⚠️ " + t("script.actions_refusees", actions=", ".join(str(x) for x in refus)))
if images:
    print()
    for chemin_image in images:
        print("[[image]] " + chemin_image)
if not reponse and not images:
    # agy met la raison dans « error » (ex. « Individual quota reached… Resets in 56m23s. »).
    erreur = str(r.get("error") or "").strip()
    if "quota" in erreur.lower():
        m = re.search(r"Resets in ((?:\d+[hms])+)", erreur)
        delai = ""
        if m:
            morceaux = dict((u, int(v)) for v, u in re.findall(r"(\d+)([hms])", m.group(1)))
            delai = " " + t("script.remise_dans", h=morceaux.get("h", 0), m="%02d" % morceaux.get("m", 0))
        print("⚠️ " + t("script.quota_epuise", nom=nom, delai=delai))
        print(erreur)
    else:
        print("⚠️ " + t("script.sans_reponse", nom=nom, statut=r.get("status"))
              + ((" : " + erreur) if erreur else ""))
    sys.exit(1)
PY
