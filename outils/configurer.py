"""Modifications prudentes des fichiers de réglages, pour install.sh et desinstaller.sh.

Chaque commande :
- lit le fichier JSON (absent ou vide = {}), et REFUSE de toucher un fichier illisible ;
- n'écrit que s'il y a vraiment quelque chose à changer ;
- copie d'abord l'original dans le dossier de sauvegarde (dossier 700, fichier 600) ;
- écrit de façon atomique (fichier provisoire puis remplacement), en gardant les droits
  de l'original (600 pour un nouveau fichier).

Messages dans la langue donnée par la variable YATEAM_LANGUE (sinon celle des réglages ou du Mac).
Codes de sortie : 0 = fait ou déjà en place, 3 = fichier illisible (rien modifié),
4 = conflit qui demande l'accord de l'utilisateur (rien modifié), 2 = mauvais usage.
Python 3.9, sans dépendance. Lancé avec /usr/bin/python3 -I.
"""
import json
import os
import random
import re
import shlex
import shutil
import sys
import tempfile
import unicodedata

DEPOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DEPOT, "equipe"))
from textes import LANGUES, Textes  # noqa: E402

t = Textes(os.environ.get("YATEAM_LANGUE"))

EVENEMENTS = ["UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop",
              "PreCompact", "Stop", "StopFailure", "PermissionRequest", "Notification", "SessionEnd"]
MARQUE_CROCHET = "/.claude/equipe/crochet_claude.py"
MARQUE_AGENT = "<!-- yateam : agent"
DEBUT_BLOC = "<!-- yateam:debut"
FIN_BLOC = "<!-- yateam:fin -->"
NOM_CONNECTEUR = "equipe"
DEFAUTS = {"codex": "Pesto", "antigravity": "Praline", "mac": "Nougat"}
CHARGES = ("codex", "antigravity")     # chargés de projet en lecture seule (agents de Claude Code)
FICHIER_NOMS = os.path.join(DEPOT, "outils", "noms.txt")


class Illisible(Exception):
    pass


class Conflit(Exception):
    pass


def dire(texte):
    print("   " + texte)


# ---------------------------------------------------------------------------
# Fichiers

def lire_json(chemin):
    if not os.path.exists(chemin):
        return {}
    try:
        with open(chemin, encoding="utf-8") as f:
            texte = f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise Illisible("%s : %s" % (chemin, e))
    if not texte.strip():
        return {}
    try:
        contenu = json.loads(texte)
    except ValueError as e:
        raise Illisible(t("conf.json_invalide", fichier=chemin, erreur=e))
    if not isinstance(contenu, dict):
        raise Illisible(t("conf.json_pas_objet", fichier=chemin))
    return contenu


def sauvegarder(chemin, dossier):
    """Copie l'original avant modification. Renvoie le chemin de la copie (ou None)."""
    if not os.path.exists(chemin):
        return None
    os.makedirs(dossier, mode=0o700, exist_ok=True)
    os.chmod(dossier, 0o700)
    base = os.path.basename(chemin)
    if "Application Support/Claude" in chemin:
        base = "app-claude-" + base
    copie = os.path.join(dossier, base)
    n = 2
    while os.path.exists(copie):
        copie = os.path.join(dossier, "%s.%d" % (base, n))
        n += 1
    shutil.copy2(chemin, copie)
    os.chmod(copie, 0o600)
    return copie


def ecrire_texte(chemin, texte):
    reel = os.path.realpath(chemin)          # un lien symbolique reste un lien
    dossier = os.path.dirname(reel)
    os.makedirs(dossier, exist_ok=True)
    droits = (os.stat(reel).st_mode & 0o777) if os.path.exists(reel) else 0o600
    descripteur, provisoire = tempfile.mkstemp(dir=dossier, prefix=".yateam-")
    try:
        with os.fdopen(descripteur, "w", encoding="utf-8") as f:
            f.write(texte)
        os.chmod(provisoire, droits)
        os.replace(provisoire, reel)
    except BaseException:
        if os.path.exists(provisoire):
            os.remove(provisoire)
        raise


def ecrire_json(chemin, contenu):
    ecrire_texte(chemin, json.dumps(contenu, indent=2, ensure_ascii=False) + "\n")


def modifier_json(chemin, sauvegardes, transformer):
    """Lit, transforme (renvoie True s'il y a un changement), sauvegarde puis écrit."""
    contenu = lire_json(chemin)
    if not transformer(contenu):
        return False
    copie = sauvegarder(chemin, sauvegardes)
    ecrire_json(chemin, contenu)
    if copie:
        dire(t("conf.sauvegarde", copie=copie))
    return True


# ---------------------------------------------------------------------------
# Crochets de Claude Code (~/.claude/settings.json)

def commande_crochet(maison):
    return "/usr/bin/python3 -I %s" % shlex.quote(os.path.join(maison, ".claude", "equipe", "crochet_claude.py"))


def est_notre_crochet(groupe):
    return isinstance(groupe, dict) and any(
        isinstance(h, dict) and MARQUE_CROCHET in str(h.get("command", "")) for h in groupe.get("hooks") or [])


def ajouter_crochets(chemin, sauvegardes, maison):
    commande = commande_crochet(maison)

    def transformer(reglages):
        crochets = reglages.get("hooks")
        if crochets is None:
            crochets = reglages["hooks"] = {}
        if not isinstance(crochets, dict):
            raise Illisible(t("conf.cle_pas_objet", fichier=chemin, cle="hooks"))
        change = False
        for evenement in EVENEMENTS:
            groupes = crochets.get(evenement)
            if groupes is None:
                groupes = crochets[evenement] = []
            if not isinstance(groupes, list):
                raise Illisible(t("conf.cle_pas_liste", fichier=chemin, cle="hooks." + evenement))
            nouveau = {"hooks": [{"type": "command", "command": commande, "timeout": 5, "async": True}]}
            anciens = [g for g in groupes if est_notre_crochet(g)]
            if anciens == [nouveau]:
                continue
            groupes[:] = [g for g in groupes if not est_notre_crochet(g)] + [nouveau]
            change = True
        return change

    if modifier_json(chemin, sauvegardes, transformer):
        dire(t("conf.crochets_ajoutes", n=len(EVENEMENTS), fichier=chemin))
    else:
        dire(t("conf.crochets_deja"))


def retirer_crochets(chemin, sauvegardes):
    def transformer(reglages):
        crochets = reglages.get("hooks")
        if not isinstance(crochets, dict):
            return False
        change = False
        for evenement in list(crochets):
            groupes = crochets[evenement]
            if not isinstance(groupes, list):
                continue
            gardes = [g for g in groupes if not est_notre_crochet(g)]
            if len(gardes) != len(groupes):
                change = True
                if gardes:
                    crochets[evenement] = gardes
                else:
                    del crochets[evenement]
        if change and not crochets:
            del reglages["hooks"]
        return change

    if not os.path.exists(chemin):
        dire(t("conf.rien_a_retirer", fichier=chemin))
    elif modifier_json(chemin, sauvegardes, transformer):
        dire(t("conf.crochets_retires", fichier=chemin))
    else:
        dire(t("conf.crochets_absents"))


# ---------------------------------------------------------------------------
# Connecteur de l'app Claude (claude_desktop_config.json)

def entree_connecteur(maison):
    return {"command": "/usr/bin/python3",
            "args": ["-I", os.path.join(maison, ".claude", "equipe", "mcp_equipe.py")]}


def est_notre_connecteur(entree):
    return isinstance(entree, dict) and any("/.claude/equipe/mcp_equipe.py" in str(a) for a in entree.get("args") or [])


def ajouter_connecteur(chemin, sauvegardes, maison, remplacer):
    nouveau = entree_connecteur(maison)

    def transformer(config):
        serveurs = config.get("mcpServers")
        if serveurs is None:
            serveurs = config["mcpServers"] = {}
        if not isinstance(serveurs, dict):
            raise Illisible(t("conf.cle_pas_objet", fichier=chemin, cle="mcpServers"))
        actuel = serveurs.get(NOM_CONNECTEUR)
        if actuel == nouveau:
            return False
        if actuel is not None and not est_notre_connecteur(actuel) and not remplacer:
            raise Conflit(t("conf.connecteur_conflit", nom=NOM_CONNECTEUR, fichier=chemin))
        serveurs[NOM_CONNECTEUR] = nouveau
        return True

    if modifier_json(chemin, sauvegardes, transformer):
        dire(t("conf.connecteur_ajoute", nom=NOM_CONNECTEUR, fichier=chemin))
    else:
        dire(t("conf.connecteur_deja"))


def retirer_connecteur(chemin, sauvegardes):
    def transformer(config):
        serveurs = config.get("mcpServers")
        if not isinstance(serveurs, dict) or not est_notre_connecteur(serveurs.get(NOM_CONNECTEUR)):
            return False
        del serveurs[NOM_CONNECTEUR]
        return True

    if not os.path.exists(chemin):
        dire(t("conf.rien_a_retirer", fichier=chemin))
    elif modifier_json(chemin, sauvegardes, transformer):
        dire(t("conf.connecteur_retire", fichier=chemin))
    else:
        dire(t("conf.connecteur_absent"))


# ---------------------------------------------------------------------------
# Réglages de YaTeam (~/.claude/equipe/config.json) et noms

def identifiant(nom, separateur):
    ascii_ = unicodedata.normalize("NFKD", nom).encode("ascii", "ignore").decode("ascii").lower()
    return re.sub(r"[^a-z0-9]+", separateur, ascii_).strip(separateur)[:40]


def verifier_noms(*noms):
    """Renvoie un message d'erreur, ou une chaîne vide si les noms conviennent (tous différents)."""
    for nom in noms:
        if not 1 <= len(nom) <= 30:
            return t("conf.nom_longueur", nom=nom)
        if not re.fullmatch(r"[\w' -]+", nom) or not identifiant(nom, "-"):
            return t("conf.nom_caracteres", nom=nom)
        if identifiant(nom, "-") == "claude":
            return t("conf.nom_reserve", nom=nom)
    slugs = [identifiant(nom, "-") for nom in noms]
    if len(set(slugs)) < len(slugs):
        return t("conf.noms_identiques")
    return ""


def tirer_noms(exclus=()):
    """Trois noms différents (ChatGPT, Gemini, Mac), tirés au hasard dans outils/noms.txt, hors des
    noms déjà choisis (par exemple avec --chatgpt-name), pour que deux membres ne s'appellent jamais pareil."""
    pris = {identifiant(n, "-") for n in exclus if n}
    with open(FICHIER_NOMS, encoding="utf-8") as f:
        noms = [l.strip() for l in f if l.strip() and not l.startswith("#")]
    return random.sample([n for n in noms if identifiant(n, "-") not in pris], 3)


def ecrire_config(chemin, sauvegardes, langue, membres, programmes):
    """membres : {"codex": {"nom": …, "actif": bool}, "antigravity": {…}, "mac": {…}}. Les autres
    réglages (widget, capacités du Mac relevées à l'installation) sont gardés."""
    def transformer(config):
        avant = json.dumps(config, sort_keys=True)
        config["version"] = 2
        config["langue"] = langue
        anciens = config.get("membres") if isinstance(config.get("membres"), dict) else {}
        nouveaux = {}
        for cle in DEFAUTS:
            m = dict(anciens.get(cle)) if isinstance(anciens.get(cle), dict) else {}
            voulu = membres.get(cle) if isinstance(membres.get(cle), dict) else {}
            m["nom"] = voulu.get("nom") or m.get("nom") or DEFAUTS[cle]
            m["actif"] = voulu.get("actif") is True
            nouveaux[cle] = m
        config["membres"] = nouveaux
        config["programmes"] = {cle: chemin for cle, chemin in programmes.items() if chemin}
        return json.dumps(config, sort_keys=True) != avant

    if modifier_json(chemin, sauvegardes, transformer):
        dire(t("conf.reglages_ecrits", fichier=chemin))
    else:
        dire(t("conf.reglages_inchanges"))


def regler(chemin, cle, valeur):
    """Écrit un réglage « a.b.c » dans config.json (sans sauvegarde : réglage relevé, pas choisi)."""
    config = lire_json(chemin)
    noeud = config
    morceaux = cle.split(".")
    for morceau in morceaux[:-1]:
        if not isinstance(noeud.get(morceau), dict):
            noeud[morceau] = {}
        noeud = noeud[morceau]
    if noeud.get(morceaux[-1]) != valeur:
        noeud[morceaux[-1]] = valeur
        ecrire_json(chemin, config)


def lire_config(chemin):
    config = lire_json(chemin)
    membres = config.get("membres") if isinstance(config.get("membres"), dict) else {}
    resultat = {}
    for cle, defaut in DEFAUTS.items():
        m = membres.get(cle) if isinstance(membres.get(cle), dict) else {}
        nom = m.get("nom") if isinstance(m.get("nom"), str) and m.get("nom").strip() else defaut
        # Un réglage d'avant la version 2 ne connaît pas le Mac : il reste éteint tant qu'on ne l'a pas choisi.
        actif = m.get("actif", cle != "mac") is True
        resultat[cle] = {"nom": nom, "actif": actif, "apple_intelligence": m.get("apple_intelligence") is True}
    langue = config.get("langue") if config.get("langue") in LANGUES else t.langue
    return resultat, langue


def nom_outil(membres, cle):
    """Même calcul que mcp_equipe.py : confier_a_<nom>, ou l'identifiant interne en cas de doublon."""
    slugs = {c: identifiant(m["nom"], "_") for c, m in membres.items()}
    slug = slugs[cle]
    if not slug or list(slugs.values()).count(slug) > 1:
        slug = cle
    return "confier_a_" + slug


def modele(langue, nom_fichier):
    for code in (langue, "en"):
        chemin = os.path.join(DEPOT, "modeles", code, nom_fichier)
        if os.path.exists(chemin):
            with open(chemin, encoding="utf-8") as f:
                return f.read()
    raise Illisible(t("conf.modele_absent", fichier=nom_fichier))


# ---------------------------------------------------------------------------
# Agents de Claude Code (~/.claude/agents/<nom>.md)

def installer_agents(config, dossier_agents, sauvegardes, manifeste, remplacer):
    """Génère un agent par chargé de projet actif ; retire ceux d'une installation précédente
    qui ne servent plus (renommage, désactivation). Conflit (code 4) si un agent du même nom,
    qui n'est pas de YaTeam, existe déjà et que `remplacer` est faux."""
    membres, langue = lire_config(config)
    voulus = {}
    for cle, m in membres.items():
        if m["actif"] and cle in CHARGES:
            voulus[os.path.join(dossier_agents, identifiant(m["nom"], "-") + ".md")] = (cle, m["nom"])
    conflits = [c for c in voulus if os.path.exists(c) and not est_notre_agent(c)]
    if conflits and not remplacer:
        raise Conflit(t("conf.agents_conflit", fichiers=", ".join(conflits)))
    anciens = lire_json(manifeste).get("agents") or []
    for ancien in anciens:
        if isinstance(ancien, str) and ancien not in voulus and os.path.exists(ancien) and est_notre_agent(ancien):
            copie = sauvegarder(ancien, sauvegardes)
            os.remove(ancien)
            dire(t("conf.agent_ancien_retire", fichier=ancien, copie=copie))
    os.makedirs(dossier_agents, exist_ok=True)
    for chemin, (cle, nom) in voulus.items():
        texte = modele(langue, "agent-%s.md" % cle)
        texte = texte.replace("{{NOM}}", nom).replace("{{ID}}", identifiant(nom, "-"))
        texte = texte.replace("{{OUTIL}}", nom_outil(membres, cle))
        if os.path.exists(chemin):
            with open(chemin, encoding="utf-8") as f:
                if f.read() == texte:
                    dire(t("conf.agent_a_jour", fichier=chemin))
                    continue
            sauvegarder(chemin, sauvegardes)
        ecrire_texte(chemin, texte)
        os.chmod(chemin, 0o644)
        dire(t("conf.agent_installe", fichier=chemin))
    noter(manifeste, agents=sorted(voulus))


def est_notre_agent(chemin):
    try:
        with open(chemin, encoding="utf-8") as f:
            return MARQUE_AGENT in f.read()
    except (OSError, UnicodeDecodeError):
        return False


def retirer_agents(manifeste, dossier_agents, sauvegardes):
    candidats = set(a for a in (lire_json(manifeste).get("agents") or []) if isinstance(a, str))
    if os.path.isdir(dossier_agents):
        candidats.update(os.path.join(dossier_agents, n) for n in os.listdir(dossier_agents) if n.endswith(".md"))
    retires = 0
    for chemin in sorted(candidats):
        if os.path.exists(chemin) and est_notre_agent(chemin):
            sauvegarder(chemin, sauvegardes)
            os.remove(chemin)
            dire(t("conf.agent_retire", fichier=chemin))
            retires += 1
    if not retires:
        dire(t("conf.agents_absents"))


# ---------------------------------------------------------------------------
# Règle de délégation dans ~/.claude/CLAUDE.md (entre balises)

def bloc_regle(membres, langue):
    """Le modèle modeles/<langue>/regle.md, avec ses lignes conditionnelles :
    {{SI_CODEX}}, {{SI_ANTIGRAVITY}} (chargé de projet actif), {{SI_DEUX}} / {{SI_UN}}."""
    actifs = [c for c in ("antigravity", "codex") if membres[c]["actif"]]
    if not actifs and not membres["mac"]["actif"]:
        return ""
    tl = Textes(langue)
    ia = {"codex": "ChatGPT", "antigravity": "Gemini"}
    mac = membres["mac"]["actif"]
    dessinent = actifs              # le Mac ne dessine pas (Image Playground refuse les apps)
    conditions = {"{{SI_CODEX}}": "codex" in actifs, "{{SI_ANTIGRAVITY}}": "antigravity" in actifs,
                  "{{SI_DEUX}}": len(actifs) == 2, "{{SI_UN}}": len(actifs) == 1, "{{SI_MAC}}": mac,
                  "{{SI_MAC_IA}}": mac and membres["mac"].get("apple_intelligence") is True,
                  "{{SI_MAC_SANS_IA}}": mac and membres["mac"].get("apple_intelligence") is not True,
                  "{{SI_IMAGES_UN}}": len(dessinent) == 1, "{{SI_IMAGES_PLUSIEURS}}": len(dessinent) > 1}
    valeurs = {
        "{{NOMS}}": tl("commun.et").join([membres[c]["nom"] for c in actifs]),
        "{{PRESENTATION}}": tl("commun.et").join("%s (%s)" % (membres[c]["nom"], ia[c]) for c in actifs),
        "{{OUTILS}}": ", ".join("`%s`" % nom_outil(membres, c) for c in actifs) + ", `faire_une_image`",
        "{{AGENTS}}": tl("commun.et").join("`%s`" % identifiant(membres[c]["nom"], "-") for c in actifs),
        "{{NOM_CODEX}}": membres["codex"]["nom"],
        "{{NOM_ANTIGRAVITY}}": membres["antigravity"]["nom"],
        "{{NOM_MAC}}": membres["mac"]["nom"],
        "{{OUTIL_MAC}}": "`%s`" % nom_outil(membres, "mac"),
        "{{DESSINATEUR}}": membres[dessinent[0]]["nom"] if dessinent else "",
        "{{DESSINATEURS}}": tl("commun.ou").join(membres[c]["nom"] for c in dessinent),
    }
    lignes = []
    # Le Mac seul (aucun chargé de projet) : règle courte, sans délégation.
    for ligne in modele(langue, "regle.md" if actifs else "regle-mac-seul.md").splitlines():
        garder = True
        for marque, vrai in conditions.items():
            if marque in ligne:
                garder = garder and vrai
                ligne = ligne.replace(marque, "")
        if not garder:
            continue
        for marque, valeur in valeurs.items():
            ligne = ligne.replace(marque, valeur)
        lignes.append(ligne)
    corps = "\n".join(lignes).strip("\n")
    return "%s (%s) -->\n%s\n%s\n" % (DEBUT_BLOC, tl("conf.bloc_gere"), corps, FIN_BLOC)


def retirer_bloc_texte(texte):
    debut = texte.find(DEBUT_BLOC)
    if debut < 0:
        return texte, False
    fin = texte.find(FIN_BLOC, debut)
    if fin < 0:
        raise Illisible(t("conf.bloc_sans_fin"))
    fin += len(FIN_BLOC)
    if texte[fin:fin + 1] == "\n":
        fin += 1
    avant = texte[:debut]
    # On retire aussi la ligne vide que l'installation avait ajoutée avant le bloc.
    if avant.endswith("\n\n"):
        avant = avant[:-1]
    return avant + texte[fin:], True


def ajouter_regle(chemin, sauvegardes, config, manifeste):
    membres, langue = lire_config(config)
    bloc = bloc_regle(membres, langue)
    texte = ""
    if os.path.exists(chemin):
        with open(chemin, encoding="utf-8") as f:
            texte = f.read()
    present = retirer_bloc_texte(texte)[1]
    if not bloc:
        dire(t("conf.regle_aucun_actif"))
        return
    if present and texte.find(bloc) >= 0:
        dire(t("conf.regle_a_jour", fichier=chemin))
        noter(manifeste, regle=True)
        return
    if present:
        debut = texte.find(DEBUT_BLOC)
        reste = texte[texte.find(FIN_BLOC, debut) + len(FIN_BLOC):]
        nouveau = texte[:debut] + bloc + (reste[1:] if reste.startswith("\n") else reste)
    else:
        nouveau = texte + ("\n" if texte and not texte.endswith("\n") else "") + ("\n" if texte else "") + bloc
    copie = sauvegarder(chemin, sauvegardes)
    ecrire_texte(chemin, nouveau)
    noter(manifeste, regle=True)
    dire(t("conf.regle_mise_a_jour" if present else "conf.regle_ajoutee", fichier=chemin))
    if copie:
        dire(t("conf.sauvegarde", copie=copie))


def retirer_regle(chemin, sauvegardes):
    if not os.path.exists(chemin):
        dire(t("conf.rien_a_retirer", fichier=chemin))
        return
    with open(chemin, encoding="utf-8") as f:
        texte = f.read()
    nouveau, present = retirer_bloc_texte(texte)
    if not present:
        dire(t("conf.regle_absente"))
        return
    sauvegarder(chemin, sauvegardes)
    ecrire_texte(chemin, nouveau)
    dire(t("conf.regle_retiree", fichier=chemin))


# ---------------------------------------------------------------------------
# Manifeste de l'installation (~/.claude/equipe/installation.json)

def noter(manifeste, **valeurs):
    contenu = lire_json(manifeste)
    contenu.update(valeurs)
    ecrire_json(manifeste, contenu)


# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        sys.exit(2)
    commande, a = sys.argv[1], sys.argv[2:]
    try:
        if commande == "ajouter-crochets":
            ajouter_crochets(a[0], a[1], a[2])
        elif commande == "retirer-crochets":
            retirer_crochets(a[0], a[1])
        elif commande == "ajouter-connecteur":
            ajouter_connecteur(a[0], a[1], a[2], len(a) > 3 and a[3] == "remplacer")
        elif commande == "retirer-connecteur":
            retirer_connecteur(a[0], a[1])
        elif commande == "verifier-noms":
            erreur = verifier_noms(*[n for n in a if n])
            if erreur:
                print(erreur)
                sys.exit(1)
        elif commande == "tirer-noms":
            print("\n".join(tirer_noms(a)))
        elif commande == "ecrire-config":
            # ecrire-config <config> <sauvegardes> <langue> <nom codex> <oui|non> <nom antigravity> <oui|non>
            #               <nom mac> <oui|non> <claude> <codex> <agy>
            ecrire_config(a[0], a[1], a[2],
                          {"codex": {"nom": a[3], "actif": a[4] == "oui"},
                           "antigravity": {"nom": a[5], "actif": a[6] == "oui"},
                           "mac": {"nom": a[7], "actif": a[8] == "oui"}},
                          {"claude": a[9], "codex": a[10], "agy": a[11]})
        elif commande == "regler":
            # regler <config> <clé> <valeur JSON> : un réglage simple (ex. membres.mac.apple_intelligence)
            regler(a[0], a[1], json.loads(a[2]))
        elif commande == "installer-agents":
            installer_agents(a[0], a[1], a[2], a[3], len(a) > 4 and a[4] == "remplacer")
        elif commande == "retirer-agents":
            retirer_agents(a[0], a[1], a[2])
        elif commande == "ajouter-regle":
            ajouter_regle(a[0], a[1], a[2], a[3])
        elif commande == "retirer-regle":
            retirer_regle(a[0], a[1])
        elif commande == "noter":
            noter(a[0], **{a[1]: json.loads(a[2])})
        elif commande == "lire":
            # lire <fichier JSON> <clé> : affiche la valeur (vide si absente)
            valeur = lire_json(a[0]).get(a[1])
            print("" if valeur is None else (valeur if isinstance(valeur, str) else json.dumps(valeur)))
        else:
            sys.exit(2)
    except Illisible as e:
        dire("⚠️ " + t("conf.illisible", erreur=e))
        sys.exit(3)
    except Conflit as e:
        dire("⚠️ %s" % e)
        sys.exit(4)
    except IndexError:
        sys.exit(2)


if __name__ == "__main__":
    main()
