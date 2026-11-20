"""Crochet (hook) de Claude Code → widget de YaTeam.

Écrit ~/.claude/equipe/etat/claude/<session>.json pour que le widget sache si
Claude travaille, attend une réponse ou est libre. Deux sources de travail, suivies à part :
- la réponse en cours : demande envoyée ou outil terminé → au travail ; fin de réponse (Stop) → finie ;
- les sous-agents, par leur identifiant (agent_id) : lancé → actif, outil terminé chez lui → actif,
  terminé → retiré. Claude Code envoie aussi des « SubagentStop » pour ses agents internes
  (suggestions de questions…) juste après Stop, sans « SubagentStart » : ils ne comptent pas
  (sinon ils rallumeraient l'icône « au travail » après chaque tour).
  Un sous-agent muet depuis 20 min est oublié (arrêté sans prévenir).
- demande d'autorisation ou question → attend votre réponse ;
- fin de session → fichier supprimé.
Branché en asynchrone (« async ») par install.sh : il ne ralentit ni ne bloque jamais Claude,
et toute erreur est ignorée en silence. Il n'écrit que des états (jamais le texte des demandes).
"""
import json
import os
import sys
import time

ETAT = os.path.expanduser("~/.claude/equipe/etat/claude")
# Les relevés de quota du widget (claude -p /usage) tournent depuis ce dossier :
# ils ne doivent pas allumer l'icône de Claude.
ATELIER = os.path.realpath(os.path.expanduser("~/.claude/equipe/atelier"))

REPONSE = {"UserPromptSubmit", "PreCompact"}
OUTILS = {"PostToolUse", "PostToolUseFailure"}
OUBLI_AGENT = 20 * 60


def journaliser(session, evenement, d, etat):
    """Journal des 300 derniers signaux, pour comprendre un état bloqué."""
    chemin = os.path.join(os.path.dirname(ETAT), "journal-crochets.log")
    ligne = "%s %s %-18s travail=%s attente=%s agents=%d\n" % (
        time.strftime("%d/%m %H:%M:%S"), session[:8], evenement,
        etat.get("au_travail"), etat.get("en_attente"), len(etat.get("agents") or {}))
    try:
        with open(chemin, encoding="utf-8") as f:
            lignes = f.readlines()[-299:]
    except FileNotFoundError:
        lignes = []
    with open(chemin, "w", encoding="utf-8") as f:
        f.writelines(lignes + [ligne])


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    session = str(d.get("session_id") or "")
    if not session or "/" in session or session.startswith("."):
        return
    if os.path.realpath(d.get("cwd") or "/").startswith(ATELIER):
        return
    evenement = d.get("hook_event_name", "")
    os.makedirs(ETAT, exist_ok=True)
    chemin = os.path.join(ETAT, session + ".json")

    if evenement == "SessionEnd":
        try:
            os.remove(chemin)
        except FileNotFoundError:
            pass
        return

    try:
        with open(chemin, encoding="utf-8") as f:
            etat = json.load(f)
    except Exception:
        etat = {}
    maintenant = time.time()
    agent = str(d.get("agent_id") or "")
    agents = etat.get("agents") if isinstance(etat.get("agents"), dict) else {}
    agents = {k: v for k, v in agents.items() if isinstance(v, (int, float)) and maintenant - v < OUBLI_AGENT}
    reponse = bool(etat.get("reponse", etat.get("au_travail")))
    attente = bool(etat.get("en_attente"))

    if evenement in REPONSE:
        reponse, attente = True, False
    elif evenement in OUTILS:
        if agent:
            agents[agent] = maintenant      # outil d'un sous-agent : la réponse principale n'est pas en cause
        else:
            reponse, attente = True, False
    elif evenement == "SubagentStart":
        if not agent:
            return
        agents[agent] = maintenant
    elif evenement == "SubagentStop":
        if agent not in agents:             # agent interne jamais annoncé : on l'ignore
            return
        del agents[agent]
    elif evenement in ("Stop", "StopFailure"):
        # Fin de réponse = disponible, sauf sous-agent encore en route (tâche de fond).
        reponse, attente = False, False
    elif evenement == "PermissionRequest":
        reponse, attente = False, True
    elif evenement == "Notification":
        genre = d.get("notification_type", "")
        if genre in ("permission_prompt", "elicitation_dialog"):
            reponse, attente = False, True
        elif genre == "idle_prompt":
            reponse, attente = False, False
        else:
            return
    else:
        return

    travail = reponse or bool(agents)
    # Après une autorisation, on reprend le même tour : le chronomètre continue.
    if travail and not etat.get("au_travail") and not etat.get("en_attente"):
        etat["depuis"] = maintenant
    etat.update(au_travail=travail, en_attente=attente and not travail, reponse=reponse, agents=agents,
                horodatage=maintenant)
    journaliser(session, evenement, d, etat)
    provisoire = "%s.%d.tmp" % (chemin, os.getpid())
    with open(provisoire, "w", encoding="utf-8") as f:
        json.dump(etat, f)
    os.replace(provisoire, chemin)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
