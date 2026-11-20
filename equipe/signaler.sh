#!/bin/zsh
# Signale au widget qu'un chargé de projet commence ou finit une tâche.
# Usage : signaler.sh <codex|antigravity> debut "<extrait de consigne>" <pid>
#         signaler.sh <codex|antigravity> fin <pid>
# Écrit ~/.claude/equipe/etat/<membre>.json. Plusieurs tâches du même membre peuvent tourner en
# même temps : la mise à jour se fait sous verrou de fichier, avec un fichier temporaire unique
# par écriture, et chaque tâche tient sa ligne dans « actifs » (par pid). Silencieux : ne doit
# jamais polluer la réponse d'un membre, ni le faire échouer.
emulate -L zsh
membre=$1; quoi=$2
[[ $membre == (codex|antigravity) ]] || exit 0
if [[ $quoi == fin ]]; then extrait=""; pid=${3:-0}; else extrait=${3:-}; pid=${4:-0}; fi
dossier="$HOME/.claude/equipe/etat"; mkdir -p "$dossier" 2>/dev/null
/usr/bin/python3 -I - "$dossier/$membre.json" "$quoi" "$extrait" "$pid" >/dev/null 2>&1 <<'PY'
import fcntl, json, os, sys, time, uuid
chemin, quoi, extrait = sys.argv[1], sys.argv[2], sys.argv[3]
pid = int(sys.argv[4]) if sys.argv[4].isdigit() else 0

def vivant(p):
    try:
        os.kill(p, 0)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return True

try:
    with open(chemin + ".verrou", "a") as verrou:
        fcntl.flock(verrou, fcntl.LOCK_EX)
        try:
            with open(chemin, encoding="utf-8") as f:
                ancien = json.load(f)
        except (OSError, ValueError):
            ancien = {}
        actifs = ancien.get("actifs") if isinstance(ancien, dict) and isinstance(ancien.get("actifs"), dict) else {}
        actifs = {p: a for p, a in actifs.items() if p.isdigit() and vivant(int(p)) and isinstance(a, dict)}
        maintenant = time.time()
        if quoi == "debut":
            actifs[str(pid)] = {"tache": " ".join(extrait.split())[:120], "debut": maintenant}
        elif pid:
            actifs.pop(str(pid), None)
        else:                       # appel sans pid : tout le monde a fini
            actifs = {}
        # Champs lus par le widget : la tâche en cours la plus récente.
        etat = {"actifs": actifs, "au_travail": bool(actifs), "horodatage": maintenant}
        if actifs:
            p, a = max(actifs.items(), key=lambda paire: paire[1].get("debut") or 0)
            etat.update(pid=int(p), tache=a.get("tache", ""), horodatage=a.get("debut") or maintenant)
        provisoire = "%s.%d.%s.tmp" % (chemin, os.getpid(), uuid.uuid4().hex[:8])
        with open(provisoire, "w", encoding="utf-8") as f:
            json.dump(etat, f, ensure_ascii=False)
        os.replace(provisoire, chemin)
except Exception:
    pass
PY
exit 0
