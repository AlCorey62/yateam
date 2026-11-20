"""Lit un réglage de ~/.claude/equipe/config.json pour les scripts zsh.

Usage : reglages.py nom <codex|antigravity>      → nom du chargé de projet (tiré au hasard à l'installation)
        reglages.py programme <claude|codex|agy> → chemin relevé à l'installation, sinon le nom seul
"""
import json
import os
import sys

DEFAUTS = {"codex": "Pesto", "antigravity": "Praline"}


def main():
    if len(sys.argv) != 3:
        sys.exit(2)
    quoi, cle = sys.argv[1], sys.argv[2]
    try:
        with open(os.path.expanduser("~/.claude/equipe/config.json"), encoding="utf-8") as f:
            config = json.load(f)
    except (OSError, ValueError):
        config = {}
    config = config if isinstance(config, dict) else {}
    if quoi == "nom":
        membre = (config.get("membres") or {}).get(cle) if isinstance(config.get("membres"), dict) else None
        nom = membre.get("nom") if isinstance(membre, dict) else None
        nom = " ".join(nom.split())[:30] if isinstance(nom, str) else ""
        print(nom or DEFAUTS.get(cle, cle))
    elif quoi == "programme":
        programmes = config.get("programmes") if isinstance(config.get("programmes"), dict) else {}
        chemin = programmes.get(cle)
        print(chemin if isinstance(chemin, str) and os.access(chemin, os.X_OK) else cle)
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
