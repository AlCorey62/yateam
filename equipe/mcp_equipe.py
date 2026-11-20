"""Connecteur MCP « Équipe » de YaTeam : donne à Claude (app de bureau : Chat, Cowork, onglet Code ;
ou Claude Code) l'accès aux membres de l'équipe qui tournent sur le Mac, et aux quotas de l'équipe :
- ChatGPT (via Codex CLI) et Gemini (via Antigravity CLI), chargés de projet en lecture seule ;
- le Mac lui-même : Rappels, Calendrier, Notes, apps et Apple Intelligence.
Chaque membre est facultatif (choisi à l'installation, modifiable ensuite).

Serveur MCP en stdio (JSON-RPC, un message par ligne), Python 3.9 sans dépendance.
Déclaré dans ~/Library/Application Support/Claude/claude_desktop_config.json par install.sh.
Textes dans la langue choisie à l'installation (langues/<code>.json, voir textes.py).
Modules : noyau.py (réglages, membres, tâches), garde.py (garde du navigateur d'Antigravity),
mac.py (membre Mac), images.py (faire_une_image).

Les tâches des chargés de projet passent par les mêmes scripts que les agents de Claude Code
(~/.claude/equipe/codex.sh, antigravity.sh) : lecture seule, réponse finale seule, et signal
d'activité pour le widget. Une tâche longue ne bloque pas : au-delà de ATTENTE_MAX secondes,
l'outil rend un numéro de tâche à passer à attendre_reponse.

Ce connecteur ne lit ni ne transmet aucun mot de passe, jeton ou identifiant : il lance les
programmes officiels (codex, agy, claude, shortcuts) déjà connectés par l'utilisateur.
"""
import os
import sys

# Lancé avec python3 -I (le dossier du script n'est alors pas dans le chemin des modules).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import json  # noqa: E402
import shutil  # noqa: E402
import signal  # noqa: E402
import subprocess  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402

import garde  # noqa: E402
import images  # noqa: E402
import mac  # noqa: E402
from noyau import (ACTIFS, ATELIER, ENV, MAISON, MEMBRES, Progression, Tache, attendre_ou_numero,  # noqa: E402
                   date_courte, enregistrer, enumerer, envoyer, journal, nom, programme, remise, t, taches,
                   verrou_taches)

VERSION = "2.0.0"
VERSIONS = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
CHARGES = [c for c in ACTIFS if c in ("antigravity", "codex")]     # chargés de projet (lecture seule)
MAC = "mac" in ACTIFS
QUESTION_MAC = MAC and MEMBRES["mac"].get("question") is True


# ---------------------------------------------------------------------------
# Présentation de l'équipe à Claude

def construire_instructions():
    if not ACTIFS:
        return t("mcp.instructions_aucun")
    morceaux = []
    if CHARGES:
        presentation = enumerer("%s (%s)" % (nom(c), MEMBRES[c]["ia"]) for c in CHARGES)
        morceaux += [t("mcp.instructions_deux" if len(CHARGES) > 1 else "mcp.instructions_un", membres=presentation),
                     t("mcp.instructions_demande", noms=enumerer((nom(c) for c in CHARGES), "commun.ou"),
                       outils=" / ".join(MEMBRES[c]["outil"] for c in CHARGES))]
        roles = []
        if "antigravity" in CHARGES:
            roles.append(t("mcp.role_antigravity", nom=nom("antigravity")))
        if "codex" in CHARGES:
            sinon = t("mcp.role_codex_sinon", nom=nom("antigravity")) if "antigravity" in CHARGES else ""
            roles.append(t("mcp.role_codex", nom=nom("codex"), sinon=sinon))
        morceaux.append(t("mcp.instructions_deleguer", roles=" ; ".join(roles)))
    else:
        morceaux.append(t("mcp.instructions_mac_seul"))
    if MAC:
        question = (t("mcp.instructions_mac_question", outil=MEMBRES["mac"]["outil"]) if QUESTION_MAC else "")
        morceaux.append(t("mcp.instructions_mac", nom=nom("mac"), question=question))
    auteurs = images.auteurs_images()
    if len(auteurs) == 1:
        morceaux.append(t("mcp.instructions_images", nom=nom(auteurs[0])))
    elif auteurs:
        morceaux.append(t("mcp.instructions_images_plusieurs",
                          auteurs=enumerer(("%s (%s)" % (nom(c), MEMBRES[c]["slug"]) for c in auteurs), "commun.ou"),
                          defaut=nom(auteurs[0])))
    if CHARGES:
        morceaux.append(t("mcp.instructions_fin"))
    return " ".join(morceaux)


INSTRUCTIONS = construire_instructions()


def schema(proprietes, obligatoires):
    return {"type": "object", "properties": proprietes, "required": obligatoires}


def texte(cle):
    return {"type": "string", "description": t(cle)}


def construire_outils():
    outils = []
    regles = " " + t("mcp.regles")
    proprietes_tache = {"consigne": texte("mcp.param_consigne"), "dossier": texte("mcp.param_dossier"),
                        "attendre": {"type": "boolean", "description": t("mcp.param_attendre")}}
    for cle in CHARGES:
        outils.append({"name": MEMBRES[cle]["outil"],
                       "description": t("mcp.outil_" + cle, nom=nom(cle)) + regles,
                       "inputSchema": schema(proprietes_tache, ["consigne"])})
    if QUESTION_MAC:
        outils.append({"name": MEMBRES["mac"]["outil"], "description": t("mcp.outil_mac", nom=nom("mac")),
                       "inputSchema": schema({"consigne": texte("mcp.param_question")}, ["consigne"])})
    if MAC:
        outils += [
            {"name": "mac_lire_rappels", "description": t("mcp.outil_lire_rappels"),
             "inputSchema": schema({"liste": texte("mcp.param_liste_lire"),
                                    "avec_faits": {"type": "boolean", "description": t("mcp.param_avec_faits")}}, [])},
            {"name": "mac_ajouter_rappels", "description": t("mcp.outil_ajouter_rappels"),
             "inputSchema": schema({"elements": {"type": "array", "items": {"type": "string"},
                                                 "description": t("mcp.param_elements_ajouter")},
                                    "liste": texte("mcp.param_liste_ajouter"),
                                    "echeance": texte("mcp.param_echeance")}, ["elements"])},
            {"name": "mac_cocher_rappels", "description": t("mcp.outil_cocher_rappels"),
             "inputSchema": schema({"liste": texte("mcp.param_liste"),
                                    "elements": {"type": "array", "items": {"type": "string"},
                                                 "description": t("mcp.param_elements_cocher")},
                                    "decocher": {"type": "boolean", "description": t("mcp.param_decocher")}},
                                   ["liste", "elements"])},
            {"name": "mac_calendrier", "description": t("mcp.outil_calendrier"),
             "inputSchema": schema({"titre": texte("mcp.param_titre_evenement"), "debut": texte("mcp.param_debut"),
                                    "fin": texte("mcp.param_fin"), "lieu": texte("mcp.param_lieu"),
                                    "notes": texte("mcp.param_notes")}, ["titre", "debut", "fin"])},
            {"name": "mac_note", "description": t("mcp.outil_note"),
             "inputSchema": schema({"titre": texte("mcp.param_titre_note"), "contenu": texte("mcp.param_contenu"),
                                    "dossier": texte("mcp.param_dossier_notes")}, ["titre", "contenu"])},
            {"name": "mac_ouvrir_app", "description": t("mcp.outil_ouvrir_app"),
             "inputSchema": schema({"nom_app": texte("mcp.param_nom_app")}, ["nom_app"])},
            {"name": "mac_lire_journal", "description": t("mcp.outil_lire_journal", nom=nom("mac")),
             "inputSchema": schema({}, [])},
        ]
    auteurs = images.auteurs_images()
    if auteurs:
        proprietes = {"description": texte("mcp.param_image_description"),
                      "destination": texte("mcp.param_image_destination"), "nom": texte("mcp.param_image_nom"),
                      "variantes": {"type": "integer", "minimum": 1, "maximum": 4,
                                    "description": t("mcp.param_image_variantes")}}
        if len(auteurs) > 1:
            proprietes["auteur"] = {"type": "string", "enum": [MEMBRES[c]["slug"] for c in auteurs],
                                    "description": t("mcp.param_image_auteur", defaut=MEMBRES[auteurs[0]]["slug"])}
        outils.append({"name": "faire_une_image",
                       "description": t("mcp.outil_image", nom=enumerer((nom(c) for c in auteurs), "commun.ou")),
                       "inputSchema": schema(proprietes, ["description", "destination"])})
    if CHARGES or auteurs:
        avec_numero = [c for c in ACTIFS if c in CHARGES or c in auteurs]
        outils.append({"name": "attendre_reponse",
                       "description": t("mcp.outil_attendre", noms=enumerer((nom(c) for c in avec_numero), "commun.ou"),
                                        outils=" / ".join([MEMBRES[c]["outil"] for c in CHARGES]
                                                          + (["faire_une_image"] if auteurs else []))),
                       "inputSchema": schema({"tache": texte("mcp.param_tache")}, ["tache"])})
    outils.append({"name": "quotas_equipe",
                   "description": t("mcp.outil_quotas", membres=enumerer(["Claude"] + [nom(c) for c in ACTIFS])),
                   "inputSchema": schema({}, [])})
    return outils


OUTILS = construire_outils()


# ---------------------------------------------------------------------------
# Tâches confiées aux chargés de projet

def manque_programme(membre):
    """Message clair si le CLI officiel n'est pas (ou plus) installé."""
    if shutil.which(programme(MEMBRES[membre]["programme"]), path=ENV["PATH"]):
        return None
    return t("commun.absent_" + membre, nom=nom(membre)) + " " + t("mcp.redemarrer_app")


def confier(membre, arguments, progression):
    entree_outil = time.time()
    consigne = arguments.get("consigne")
    consigne = consigne.strip() if isinstance(consigne, str) else ""
    if not consigne:
        return t("mcp.consigne_vide"), True
    dossier = arguments.get("dossier")
    dossier = os.path.expanduser((dossier.strip() if isinstance(dossier, str) else "") or ATELIER)
    os.makedirs(ATELIER, exist_ok=True)
    if not os.path.isdir(dossier):
        return t("mcp.dossier_introuvable", dossier=dossier), True
    manque = manque_programme(membre)
    if manque:
        return manque, True
    tache = Tache(membre, consigne, os.path.realpath(dossier))
    enregistrer(tache)
    journal(t("mcp.j_tache", tache=tache.id, dossier=dossier))
    if arguments.get("attendre") is False:
        return t("mcp.tache_recue", nom=nom(membre), tache=tache.id), False
    return attendre_ou_numero(tache, progression, entree_outil)


def attendre_reponse(arguments, progression):
    numero = arguments.get("tache")
    numero = numero.strip() if isinstance(numero, str) else ""
    with verrou_taches:
        tache = taches.get(numero)
    if tache is None:
        return t("mcp.tache_inconnue", tache=numero or "—"), True
    return attendre_ou_numero(tache, progression)


# ---------------------------------------------------------------------------
# Quotas (mêmes sources officielles que le widget, 0 jeton)

def executer(commande, delai=90):
    try:
        r = subprocess.run(commande, cwd=ATELIER, env=ENV, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=delai)
        return r.stdout
    except Exception as erreur:   # programme absent, délai dépassé…
        journal(t("mcp.j_echec", programme=commande[0], erreur=erreur))
        return ""


def iso_vers_epoch(texte_date):
    if not texte_date:
        return None
    try:
        from datetime import datetime
        return datetime.fromisoformat(str(texte_date).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def ligne(titre, utilise, reinit):
    return "  " + t("mcp.q_ligne", titre=titre, pct=round(utilise * 100), remise=remise(reinit))


def quotas_claude():
    sortie = executer([programme("claude"), "-p", "/usage", "--output-format", "stream-json", "--verbose",
                       "--no-session-persistence", "--settings", '{"disableAllHooks":true}'], 60)
    for brut in sortie.splitlines():
        try:
            e = json.loads(brut)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        limites = (((e.get("usage_report") or {}).get("rate_limits") or {}).get("limits"))
        if not isinstance(limites, list) or not limites:
            continue
        lignes = [t("mcp.q_claude")]
        noms_limites = {"session": t("commun.cinq_heures"), "weekly_all": t("commun.semaine")}
        for l in limites:
            if not isinstance(l, dict):
                continue
            titre = noms_limites.get(l.get("kind"))
            if titre is None and l.get("kind") == "weekly_scoped":
                modele = (((l.get("scope") or {}).get("model") or {}).get("display_name")) or t("mcp.q_modele")
                titre = t("mcp.q_semaine_modele", modele=modele)
            if titre:
                p = (l.get("percent") or 0) / 100.0
                lignes.append(ligne(titre, p, iso_vers_epoch(l.get("resets_at")) if p > 0 else None))
        return "\n".join(lignes)
    return t("mcp.q_claude_indispo")


def quotas_antigravity():
    sortie, reconnexion = garde.executer_agy(["-p", "/quota", "--output-format", "json", "--print-timeout", "60s"], 90)
    if reconnexion:
        return t("mcp.q_antigravity_reconnexion", nom=nom("antigravity")) + "\n" + images.ligne_images("antigravity")
    try:
        groupes = json.loads(sortie)["command"]["data"]["groups"]
    except (ValueError, KeyError, TypeError):
        return t("mcp.q_antigravity_indispo", nom=nom("antigravity")) + "\n" + images.ligne_images("antigravity")
    reserves = {}
    for g in groupes if isinstance(groupes, list) else []:
        for s in (g.get("buckets") if isinstance(g, dict) else None) or []:
            if not isinstance(s, dict):
                continue
            cle = ("tiers" if str(s.get("id", "")).startswith("3p") else "gemini", s.get("window"))
            try:
                reste = float(s.get("remaining_fraction", 1))
            except (TypeError, ValueError):
                continue
            if cle not in reserves or reserves[cle][0] < 1 - reste:
                reserves[cle] = (1 - reste, None if reste >= 0.9999 else iso_vers_epoch(s.get("reset_time")))
    lignes = [t("mcp.q_antigravity", nom=nom("antigravity"))]
    for reserve in ["gemini", "tiers"]:
        for fenetre, titre in [("5h", t("commun.cinq_heures")), ("weekly", t("commun.semaine"))]:
            if (reserve, fenetre) in reserves:
                u, r = reserves[(reserve, fenetre)]
                lignes.append(ligne(titre if reserve == "gemini" else titre + "*", u, r))
    lignes.append(images.ligne_images("antigravity"))
    if any(c[0] == "tiers" for c in reserves):
        lignes.append("  " + t("mcp.q_tiers", nom=nom("antigravity")))
    return "\n".join(lignes)


FORMULES_CHATGPT = {"plus": "ChatGPT Plus", "free": "ChatGPT Free", "pro": "ChatGPT Pro", "team": "ChatGPT Team",
                    "business": "ChatGPT Business", "enterprise": "ChatGPT Enterprise", "edu": "ChatGPT Edu"}


def quotas_codex():
    racine = os.path.join(MAISON, ".codex", "sessions")
    fichiers = []
    for dossier, _, noms_fichiers in os.walk(racine):
        for nom_fichier in noms_fichiers:
            if nom_fichier.endswith(".jsonl"):
                chemin = os.path.join(dossier, nom_fichier)
                try:
                    fichiers.append((os.path.getmtime(chemin), chemin))
                except OSError:
                    pass
    for date_fichier, chemin in sorted(fichiers, reverse=True)[:6]:
        try:
            with open(chemin, "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 512 * 1024))
                lignes_fichier = f.read().decode("utf-8", "ignore").splitlines()
        except OSError:
            continue
        for brut in reversed(lignes_fichier):
            if '"rate_limits"' not in brut:
                continue
            try:
                limites = json.loads(brut).get("payload", {}).get("rate_limits") or {}
            except (ValueError, AttributeError):
                continue
            if not isinstance(limites, dict) or "primary" not in limites:
                continue
            formule = FORMULES_CHATGPT.get(str(limites.get("plan_type")), "ChatGPT")
            lignes = [t("mcp.q_codex", nom=nom("codex"), formule=formule, date=date_courte(date_fichier))]
            for cle, titre in [("primary", t("commun.cinq_heures")), ("secondary", t("commun.semaine"))]:
                f = limites.get(cle) or {}
                if isinstance(f, dict) and "used_percent" in f:
                    lignes.append(ligne(titre, f["used_percent"] / 100.0, f.get("resets_at")))
            lignes.append(images.ligne_images("codex"))
            return "\n".join(lignes)
    return t("mcp.q_codex_aucun", nom=nom("codex")) + "\n" + images.ligne_images("codex")


def quotas_mac():
    return t("mcp.q_mac", nom=nom("mac"))


def quotas_equipe():
    os.makedirs(ATELIER, exist_ok=True)
    sources = [("claude", "Claude", quotas_claude)]
    for cle, fonction in (("codex", quotas_codex), ("antigravity", quotas_antigravity), ("mac", quotas_mac)):
        if cle in ACTIFS:
            sources.append((cle, nom(cle), fonction))
    resultats = {}

    def relever(cle, nom_membre, fonction):
        try:
            resultats[cle] = fonction()
        except Exception as erreur:       # réponse inattendue d'un programme : message clair
            resultats[cle] = t("mcp.q_erreur", nom=nom_membre, erreur=erreur)
    fils = [threading.Thread(target=relever, args=(c, n, f), daemon=True) for c, n, f in sources]
    for fil in fils:
        fil.start()
    for fil in fils:
        fil.join(100)
    return "\n\n".join(resultats.get(c, t("mcp.q_trop_long", nom=n)) for c, n, _ in sources), False


# ---------------------------------------------------------------------------
# Protocole MCP

OUTILS_MAC = {"mac_lire_rappels": mac.mac_lire_rappels, "mac_ajouter_rappels": mac.mac_ajouter_rappels,
              "mac_cocher_rappels": mac.mac_cocher_rappels, "mac_calendrier": mac.mac_calendrier,
              "mac_note": mac.mac_note, "mac_ouvrir_app": mac.mac_ouvrir_app,
              "mac_lire_journal": mac.mac_lire_journal}
NOMS_OUTILS = {o["name"] for o in OUTILS}


def appel_outil(identifiant_requete, params):
    try:
        nom_outil = params.get("name")
        arguments = params.get("arguments")
        if arguments is None:
            arguments = {}
        if not isinstance(nom_outil, str) or not isinstance(arguments, dict):
            envoyer({"jsonrpc": "2.0", "id": identifiant_requete,
                     "error": {"code": -32602, "message": t("mcp.params_invalides")}})
            return
        progression = Progression(params)
        membre = next((c for c in CHARGES if MEMBRES[c]["outil"] == nom_outil), None)
        if nom_outil not in NOMS_OUTILS:
            envoyer({"jsonrpc": "2.0", "id": identifiant_requete,
                     "error": {"code": -32602, "message": t("mcp.outil_inconnu", nom=nom_outil)}})
            return
        if membre:
            retour = confier(membre, arguments, progression)
        elif QUESTION_MAC and nom_outil == MEMBRES["mac"]["outil"]:
            retour = mac.confier_mac(arguments, progression)
        elif nom_outil in OUTILS_MAC:
            retour = OUTILS_MAC[nom_outil](arguments)
        elif nom_outil == "faire_une_image":
            retour = images.faire_une_image(arguments, progression, manque_programme)
        elif nom_outil == "attendre_reponse":
            retour = attendre_reponse(arguments, progression)
        else:
            retour = quotas_equipe()
    except Exception as e:   # ne jamais laisser l'app sans réponse
        retour = (t("mcp.erreur_connecteur", erreur=e), True)
    texte_retour, erreur = retour[0], retour[1]
    apercus = retour[2] if len(retour) > 2 else []
    envoyer({"jsonrpc": "2.0", "id": identifiant_requete,
             "result": {"content": [{"type": "text", "text": texte_retour}] + list(apercus),
                        "isError": bool(erreur)}})


def traiter(message):
    if not isinstance(message, dict):
        envoyer({"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": t("mcp.requete_invalide")}})
        return
    methode = message.get("method")
    identifiant_requete = message.get("id")
    params = message.get("params")
    if params is None:
        params = {}
    if identifiant_requete is None:          # notification (ou réponse) : rien à répondre
        return
    if not isinstance(methode, str) or not isinstance(params, dict):
        envoyer({"jsonrpc": "2.0", "id": identifiant_requete,
                 "error": {"code": -32600, "message": t("mcp.requete_invalide")}})
        return
    if methode == "initialize":
        demandee = params.get("protocolVersion")
        envoyer({"jsonrpc": "2.0", "id": identifiant_requete, "result": {
            "protocolVersion": demandee if demandee in VERSIONS else VERSIONS[-1],
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "equipe", "version": VERSION},
            "instructions": INSTRUCTIONS,
        }})
    elif methode == "ping":
        envoyer({"jsonrpc": "2.0", "id": identifiant_requete, "result": {}})
    elif methode == "tools/list":
        envoyer({"jsonrpc": "2.0", "id": identifiant_requete, "result": {"tools": OUTILS}})
    elif methode == "tools/call":
        threading.Thread(target=appel_outil, args=(identifiant_requete, params), daemon=True).start()
    else:
        envoyer({"jsonrpc": "2.0", "id": identifiant_requete,
                 "error": {"code": -32601, "message": t("mcp.methode_inconnue", methode=methode)}})


def tout_arreter(*_):
    with verrou_taches:
        en_cours = [x for x in taches.values() if not x.fini.is_set()]
    for x in en_cours:
        x.arreter()
    sys.exit(0)


def main():
    journal(t("mcp.j_demarre", membres=enumerer(nom(c) for c in ACTIFS) or "—", langue=t.langue))
    signal.signal(signal.SIGTERM, tout_arreter)
    for brut in sys.stdin:
        brut = brut.strip()
        if not brut:
            continue
        try:
            message = json.loads(brut)
        except ValueError:
            envoyer({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": t("mcp.json_illisible")}})
            continue
        if isinstance(message, list) and not message:
            envoyer({"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": t("mcp.requete_invalide")}})
            continue
        for m in (message if isinstance(message, list) else [message]):
            try:
                traiter(m)
            except Exception as erreur:   # filet de sécurité : la boucle ne s'arrête jamais
                journal(t("mcp.j_ignore", erreur=erreur))
    tout_arreter()


if __name__ == "__main__":
    main()
