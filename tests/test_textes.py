"""Cohérence des traductions de YaTeam (sans rien installer).

- chaque langue a exactement les mêmes clés que le français (langue de référence) ;
- chaque texte garde les mêmes valeurs à insérer ({nom}, {n}…) que le français ;
- chaque clé utilisée dans le code existe ;
- chaque langue a ses modèles d'agents et de règle, avec les mêmes marques que le français.
"""
import json
import os
import re
import sys

DEPOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGUES = ["en", "fr", "de", "es", "it", "ja", "zh"]
echecs = []


def verifier(condition, message):
    if not condition:
        echecs.append(message)
        print("  ✗ " + message)


def valeurs(texte):
    return sorted(set(re.findall(r"\{([a-z_]+)\}", texte)))


def charger(code):
    with open(os.path.join(DEPOT, "equipe", "langues", code + ".json"), encoding="utf-8") as f:
        return json.load(f)


reference = charger("fr")
for code in LANGUES:
    try:
        catalogue = charger(code)
    except (OSError, ValueError) as e:
        verifier(False, "%s.json illisible : %s" % (code, e))
        continue
    manquantes = sorted(set(reference) - set(catalogue))
    en_trop = sorted(set(catalogue) - set(reference))
    verifier(not manquantes, "%s : clés manquantes %s" % (code, manquantes))
    verifier(not en_trop, "%s : clés en trop %s" % (code, en_trop))
    for cle, texte in catalogue.items():
        if cle in reference:
            verifier(valeurs(texte) == valeurs(reference[cle]),
                     "%s / %s : valeurs %s au lieu de %s" % (code, cle, valeurs(texte), valeurs(reference[cle])))
        verifier(isinstance(texte, str) and texte.strip(), "%s / %s : texte vide" % (code, cle))
    verifier(len(catalogue.get("commun.jours", "").split("|")) == 7, "%s : il faut 7 jours" % code)

# Clés utilisées dans le code
motifs = [r'\bt\("([a-z_.]+)"', r'tl\("([a-z_.]+)"', r'Textes\.t\("([a-z_.]+)"', r'\$\(t ([a-z_.]+)',
          r'texte ((?:script|commun)\.[a-z_]+)', r'"((?:mcp|mac|img|commun|conf|inst|desinst|widget|script)\.[a-z0-9_]+)"',
          r'(?<![\w.$])(inst\.[a-z0-9_]+)\b']
# Clés construites dans le code (préfixe + code d'erreur, clé du membre…)
DYNAMIQUES = ("commun.absent_", "mac.e_", "mac.raison_", "mac.date_manquante_", "mcp.outil_", "inst.fin_exemple_")
utilisees = set()
for racine, _, fichiers in os.walk(DEPOT):
    if any(p in racine for p in ("/.git", "/.build", "/build", "/tests")):
        continue
    for nom in fichiers:
        if nom.endswith((".py", ".sh", ".swift")):
            with open(os.path.join(racine, nom), encoding="utf-8") as f:
                contenu = f.read()
            for motif in motifs:
                utilisees.update(re.findall(motif, contenu))
inconnues = sorted(c for c in utilisees if c not in reference and c not in DYNAMIQUES and not c.endswith((".", ".json", ".py", ".txt")))
verifier(not inconnues, "clés utilisées dans le code mais absentes de fr.json : %s" % inconnues)
inutiles = sorted(c for c in reference if c not in utilisees and not c.startswith(DYNAMIQUES))
verifier(not inutiles, "clés de fr.json jamais utilisées : %s" % inutiles)

# Modèles d'agents et de règle
marques = re.compile(r"\{\{[A-Z_]+\}\}")
for fichier in ("agent-codex.md", "agent-antigravity.md", "regle.md", "regle-mac-seul.md"):
    with open(os.path.join(DEPOT, "modeles", "fr", fichier), encoding="utf-8") as f:
        attendu = sorted(set(marques.findall(f.read())))
    for code in LANGUES:
        chemin = os.path.join(DEPOT, "modeles", code, fichier)
        if not os.path.exists(chemin):
            verifier(False, "modèle manquant : %s/%s" % (code, fichier))
            continue
        with open(chemin, encoding="utf-8") as f:
            contenu = f.read()
        verifier(sorted(set(marques.findall(contenu))) == attendu, "%s/%s : marques différentes du français" % (code, fichier))
        if fichier.startswith("agent"):
            verifier("<!-- yateam : agent" in contenu, "%s/%s : marque d'agent YaTeam absente" % (code, fichier))

print("  ✓ traductions cohérentes (%d clés, %d langues)" % (len(reference), len(LANGUES)) if not echecs
      else "%d problème(s) dans les traductions" % len(echecs))
sys.exit(1 if echecs else 0)
