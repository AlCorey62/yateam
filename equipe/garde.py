"""Garde du navigateur pour Antigravity (agy).

Quand la connexion Google d'Antigravity est à refaire, agy lance « open <page de connexion> » :
sans garde, des pages de connexion s'ouvraient en boucle à chaque relevé automatique. Tout appel
d'agy passe donc par un faux « open » placé en tête du PATH, qui note la demande au lieu d'ouvrir
une page. Dès qu'il est appelé (ou qu'agy répond « authentication required »), agy est arrêté et
Claude reçoit un message clair : l'utilisateur se reconnecte lui-même en lançant `agy` dans le Terminal.

Le même faux « open » est écrit par antigravity.sh et par le widget, à l'octet près.
"""
import os
import re
import subprocess
import threading
import time

from noyau import ATELIER, ENV, EQUIPE, arreter_groupe, journal, programme, t

GARDE = os.path.join(EQUIPE, "garde")
GARDE_BIN = os.path.join(GARDE, "bin")
SIGNAL_NAVIGATEUR = os.path.join(GARDE, "navigateur-demande.log")
SCRIPT_GARDE = ("#!/bin/sh\n"
                "# YaTeam: an automatic check never opens the browser.\n"
                "echo \"$(date '+%%Y-%%m-%%d %%H:%%M:%%S') open request blocked\" >> \"%s\"\n"
                "exit 0\n") % SIGNAL_NAVIGATEUR
MOTIF_RECONNEXION = re.compile(r"authentication (required|failed)|log ?in, then retry", re.I)


def preparer_garde():
    """Crée (ou remet d'aplomb) les faux « open » et « xdg-open ». Renvoie False en cas d'échec.
    Le chemin du signal est écrit entre guillemets dans le script : un caractère qui les casserait
    (impossible dans un nom de compte macOS, mais on ne prend aucun risque) annule la garde."""
    if any(c in SIGNAL_NAVIGATEUR for c in '"$`\\'):
        journal(t("mcp.j_garde_impossible", erreur=SIGNAL_NAVIGATEUR))
        return False
    try:
        os.makedirs(GARDE_BIN, exist_ok=True)
        for nom_faux in ("open", "xdg-open"):
            chemin = os.path.join(GARDE_BIN, nom_faux)
            try:
                with open(chemin, encoding="utf-8") as f:
                    actuel = f.read()
            except OSError:
                actuel = None
            if actuel != SCRIPT_GARDE:
                with open(chemin, "w", encoding="utf-8") as f:
                    f.write(SCRIPT_GARDE)
            os.chmod(chemin, 0o755)
        return True
    except OSError as erreur:
        journal(t("mcp.j_garde_impossible", erreur=erreur))
        return False


def demande_navigateur(depuis):
    """Le faux « open » a-t-il été appelé depuis l'instant `depuis` ?"""
    try:
        return os.path.getmtime(SIGNAL_NAVIGATEUR) >= depuis
    except OSError:
        return False


def executer_agy(arguments, delai=90):
    """Lance agy sous garde. Renvoie (sortie, reconnexion_requise). Sans garde, n'appelle pas agy."""
    if not preparer_garde():
        return "", False
    debut = time.time()
    env = dict(ENV, PATH=GARDE_BIN + ":" + ENV["PATH"])
    try:
        processus = subprocess.Popen([programme("agy")] + arguments, cwd=ATELIER, env=env,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, errors="replace", start_new_session=True)
    except OSError as erreur:
        journal(t("mcp.j_echec", programme="agy", erreur=erreur))
        return "", False
    lus = {}
    lecteurs = [threading.Thread(target=lambda n=n, flux=flux: lus.__setitem__(n, flux.read()), daemon=True)
                for n, flux in (("sortie", processus.stdout), ("erreurs", processus.stderr))]
    for lecteur in lecteurs:
        lecteur.start()
    reconnexion = False
    while processus.poll() is None:
        if demande_navigateur(debut):
            reconnexion = True
            break
        if time.time() - debut > delai:
            journal(t("mcp.j_agy_arrete", s=delai))
            break
        time.sleep(0.5)
    if processus.poll() is None:
        arreter_groupe(processus)
    for lecteur in lecteurs:
        lecteur.join(5)
    sortie = lus.get("sortie") or ""
    if demande_navigateur(debut) or MOTIF_RECONNEXION.search(sortie + (lus.get("erreurs") or "")):
        reconnexion = True
        journal(t("mcp.j_reconnexion"))
    return sortie, reconnexion
