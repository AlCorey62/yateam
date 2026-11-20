"""Textes de YaTeam dans la langue choisie à l'installation.

Les traductions sont dans langues/<code>.json (à côté de ce fichier) ; la langue est
lue dans ~/.claude/equipe/config.json (« langue »), sinon celle du Mac, sinon l'anglais.
Les valeurs à insérer s'écrivent {nom} dans les textes.

Utilisé par le connecteur, les scripts et install.sh / desinstaller.sh :
  textes.py shell <langue>          → déclarations zsh (tableau T) pour les scripts
  textes.py texte <clé> [nom=val…]  → un texte, dans la langue configurée
  textes.py langue-du-mac           → code de la langue du Mac (en si elle n'est pas prise en charge)
Python 3.9, sans dépendance.
"""
import json
import os
import shlex
import subprocess
import sys

LANGUES = {"en": "English", "fr": "Français", "de": "Deutsch", "es": "Español",
           "it": "Italiano", "ja": "日本語", "zh": "中文"}
DOSSIER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "langues")
CONFIG = os.path.expanduser("~/.claude/equipe/config.json")
SECOURS = "en"


def langue_du_mac():
    try:
        sortie = subprocess.run(["/usr/bin/defaults", "read", "-g", "AppleLanguages"],
                                capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return SECOURS
    for morceau in sortie.replace("(", " ").replace(")", " ").replace(",", " ").split():
        code = morceau.strip().strip('"').lower()
        if code[:2] in LANGUES:
            return code[:2]
        if code:
            return SECOURS
    return SECOURS


def langue_configuree():
    try:
        with open(CONFIG, encoding="utf-8") as f:
            langue = json.load(f).get("langue")
        if langue in LANGUES:
            return langue
    except (OSError, ValueError, AttributeError):
        pass
    return langue_du_mac()


def charger(langue, dossier=DOSSIER):
    try:
        with open(os.path.join(dossier, "%s.json" % langue), encoding="utf-8") as f:
            contenu = json.load(f)
        return contenu if isinstance(contenu, dict) else {}
    except (OSError, ValueError):
        return {}


class Textes:
    def __init__(self, langue=None, dossier=DOSSIER):
        self.langue = langue if langue in LANGUES else langue_configuree()
        self.catalogue = charger(self.langue, dossier)
        self.secours = charger(SECOURS, dossier) if self.langue != SECOURS else {}

    def __call__(self, cle, **valeurs):
        texte = self.catalogue.get(cle) or self.secours.get(cle) or cle
        for nom, valeur in valeurs.items():
            texte = texte.replace("{%s}" % nom, str(valeur))
        return texte

    def liste(self, cle):
        """Texte « a|b|c » → liste (ex. les jours de la semaine)."""
        return self(cle).split("|")


def main():
    if sys.argv[1:2] == ["shell"]:
        langue = sys.argv[2] if len(sys.argv) > 2 else None
        t = Textes(langue)
        cles = sorted(set(t.secours) | set(t.catalogue))
        print("typeset -gA T")
        print("T=(" + " ".join("%s %s" % (shlex.quote(c), shlex.quote(t(c))) for c in cles) + ")")
        print("LANGUE=%s" % shlex.quote(t.langue))
    elif sys.argv[1:2] == ["texte"] and len(sys.argv) > 2:
        valeurs = dict(a.split("=", 1) for a in sys.argv[3:] if "=" in a)
        print(Textes()(sys.argv[2], **valeurs))
    elif sys.argv[1:2] == ["langue-du-mac"]:
        print(langue_du_mac())
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
