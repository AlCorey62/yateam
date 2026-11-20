"""Membre « Mac » de YaTeam : Rappels, Calendrier, Notes, ouverture d'apps, questions à Apple
Intelligence, sur le Mac lui-même, sans aucun raccourci à créer.

- Rappels, Calendrier, Notes et questions : YaTeamMac.app (EventKit, AppleScript, FoundationModels),
  petite app sans fenêtre construite à l'installation (sources dans mac/). Lancée par
  `open`, elle a ses propres autorisations (Rappels ; Calendrier en écriture seule ; « Automatisation »
  pour Notes), demandées une fois à l'installation.
- Apps : commande `open` du Mac, sur le chemin exact de l'app.
Chaque action réussie est notée dans un journal local (etat/journal-mac.txt), relu par mac_lire_journal.
Aucun outil n'envoie de message, de mail ni d'invitation.
"""
import difflib
import fcntl
import html
import json
import os
import re
import subprocess
import tempfile
import threading
import time

from noyau import (ENV, EQUIPE, ETAT, arreter_groupe, journal, mettre_a_jour_json, nom, normaliser,
                   processus_vivant, t, texte_argument)

APP_MAC = os.path.join(EQUIPE, "YaTeamMac.app")
# Tests (tests/lancer_tests.sh) : un faux YaTeamMac lancé directement, sans `open` ni autorisation.
OUTIL_TEST = os.environ.get("YATEAM_TEST_OUTIL_MAC")
ETAT_MAC = os.path.join(ETAT, "mac.json")
JOURNAL_MAC = os.path.join(ETAT, "journal-mac.txt")
LIGNES_JOURNAL = 400          # au-delà, les plus anciennes lignes sont retirées
DOSSIERS_APPS = ["/Applications", "/Applications/Utilities", "/System/Applications",
                 "/System/Applications/Utilities", os.path.expanduser("~/Applications")]
ATTENTE_VERROU = 15           # s : une seule action du Mac à la fois
VERROU_MAC = os.path.join(ETAT, "mac-action.verrou")

verrou_mac = threading.Lock()


class VerrouPartage:
    """Une action du Mac à la fois, entre tous les connecteurs (un par conversation) : verrou de
    fichier pris sans bloquer, réessayé jusqu'à `attente` secondes."""

    def __init__(self, chemin, attente):
        self.chemin, self.attente, self.fichier = chemin, attente, None

    def prendre(self):
        limite = time.time() + self.attente
        try:
            os.makedirs(os.path.dirname(self.chemin), exist_ok=True)
            self.fichier = open(self.chemin, "a")
        except OSError:
            return True              # pas de fichier de verrou possible : le verrou du processus suffit
        while True:
            try:
                fcntl.flock(self.fichier, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except OSError:
                if time.time() >= limite:
                    self.fichier.close()
                    self.fichier = None
                    return False
                time.sleep(0.2)

    def rendre(self):
        if self.fichier is not None:
            try:
                fcntl.flock(self.fichier, fcntl.LOCK_UN)
            finally:
                self.fichier.close()
                self.fichier = None


# ---------------------------------------------------------------------------
# Suivi pour le widget (etat/mac.json) et journal local

def signaler_mac(au_travail, libelle="", bilan=None, reussi=False):
    """Prévient le widget, comme signaler.sh pour les autres membres, et tient le compte des actions
    réussies du jour. Chaque connecteur (un par conversation) tient sa ligne dans « actifs » (par pid)."""
    def modifier(etat):
        maintenant = time.time()
        jour = time.strftime("%Y-%m-%d")
        if etat.get("jour") != jour:
            etat.update(jour=jour, actions_jour=0)
        actifs = etat.get("actifs") if isinstance(etat.get("actifs"), dict) else {}
        actifs = {pid: a for pid, a in actifs.items()
                  if pid.isdigit() and processus_vivant(int(pid)) and isinstance(a, dict)}
        if au_travail:
            actifs[str(os.getpid())] = {"tache": libelle[:120], "debut": maintenant}
        else:
            actifs.pop(str(os.getpid()), None)
            if bilan:
                etat.update(derniere=bilan[:200], derniere_horodatage=maintenant, derniere_ok=reussi)
                if reussi:
                    etat["actions_jour"] = int(etat.get("actions_jour") or 0) + 1
        etat["actifs"] = actifs
        etat.update(au_travail=bool(actifs), horodatage=maintenant)
        etat.pop("pid", None)
        etat.pop("tache", None)
        if actifs:
            pid, recent = max(actifs.items(), key=lambda paire: paire[1].get("debut") or 0)
            etat.update(pid=int(pid), tache=recent.get("tache", ""), horodatage=recent.get("debut") or maintenant)
    mettre_a_jour_json(ETAT_MAC, modifier)


def ecrire_journal(description):
    """Ajoute « AAAA-MM-JJ HH:MM  description » à la fin du journal local (sous verrou)."""
    try:
        os.makedirs(ETAT, exist_ok=True)
        with open(JOURNAL_MAC + ".verrou", "a") as verrou:
            fcntl.flock(verrou, fcntl.LOCK_EX)
            try:
                with open(JOURNAL_MAC, encoding="utf-8") as f:
                    lignes = f.read().splitlines()
            except OSError:
                lignes = []
            lignes.append("%s  %s" % (time.strftime("%Y-%m-%d %H:%M"), " ".join(description.split())))
            provisoire = "%s.%d.tmp" % (JOURNAL_MAC, os.getpid())
            with open(os.open(provisoire, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f:
                f.write("\n".join(lignes[-LIGNES_JOURNAL:]) + "\n")
            os.replace(provisoire, JOURNAL_MAC)
    except Exception as erreur:
        journal(t("mac.j_journal_impossible", erreur=erreur))


def mac_lire_journal(arguments=None):
    try:
        with open(JOURNAL_MAC, encoding="utf-8") as f:
            lignes = f.read().splitlines()
    except OSError:
        lignes = []
    if not lignes:
        return t("mac.journal_vide"), False
    debut = "" if len(lignes) <= 60 else t("mac.journal_tronque", n=len(lignes) - 60) + "\n"
    return t("mac.journal", nom=nom("mac")) + "\n\n" + debut + "\n".join(lignes[-60:]), False


def action_mac(libelle, description, faire):
    """Une action du Mac : une à la fois, suivie par le widget (`libelle` pendant le travail), notée
    dans le journal si elle réussit. `faire()` renvoie (texte, erreur) ; `description` est la ligne du journal."""
    debut = time.time()
    if not verrou_mac.acquire(timeout=ATTENTE_VERROU):
        return t("mac.e_occupe", nom=nom("mac")), True
    partage = VerrouPartage(VERROU_MAC, max(1, ATTENTE_VERROU - (time.time() - debut)))
    if not partage.prendre():
        verrou_mac.release()
        return t("mac.e_occupe", nom=nom("mac")), True
    try:
        signaler_mac(True, libelle)
        reussi = False
        try:
            texte, erreur = faire()
            reussi = not erreur
            if reussi:
                ecrire_journal(description)
            return texte, erreur
        finally:
            signaler_mac(False, bilan=description if reussi else t("mac.echec_de", action=libelle), reussi=reussi)
    finally:
        partage.rendre()
        verrou_mac.release()


# ---------------------------------------------------------------------------
# YaTeamMac.app

def message_erreur(reponse):
    """Message clair, dans la langue choisie, d'après le code d'erreur rendu par YaTeamMac.app."""
    code = str(reponse.get("code") or "inconnue")
    valeurs = {k: v for k, v in reponse.items() if k not in ("ok", "code")}
    if code == "ia_indisponible":
        raison = str(valeurs.get("raison") or "")
        texte_raison = t("mac.raison_" + raison)
        valeurs["raison"] = raison if texte_raison == "mac.raison_" + raison else texte_raison
    cle = "mac.e_" + code
    texte = t(cle, **valeurs)
    if texte == cle:
        texte = t("mac.e_inconnue", code=code, detail=json.dumps(valeurs, ensure_ascii=False))
    return texte


def outil_mac(arguments, delai=40):
    """Lance YaTeamMac.app (en arrière-plan) et lit sa réponse JSON. Renvoie (réponse, None) ou (None, message clair)."""
    if not OUTIL_TEST and not os.path.isdir(APP_MAC):
        return None, t("mac.e_app_absente", nom=nom("mac"))
    # Un caractère NUL ne peut pas passer dans les arguments d'un processus (ValueError) : retiré.
    arguments = [str(a).replace("\x00", "") for a in arguments]
    descripteur, sortie = tempfile.mkstemp(prefix="yateam-mac-", suffix=".json")
    os.close(descripteur)
    options = ["-W", "-n", "-g"]
    lancement = ([OUTIL_TEST, sortie] if OUTIL_TEST
                 else ["/usr/bin/open"] + options + ["-a", APP_MAC, "--args", sortie])
    try:
        processus = subprocess.Popen(lancement + arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, errors="replace", env=ENV, start_new_session=True)
        try:
            messages, _ = processus.communicate(timeout=delai)
        except subprocess.TimeoutExpired:
            arreter_groupe(processus)
            # L'app est lancée par LaunchServices, hors du groupe d'« open » : on l'arrête par son
            # fichier de sortie, unique, présent dans ses arguments (elle s'arrête d'elle-même avant).
            try:
                subprocess.run(["/usr/bin/pkill", "-f", sortie], capture_output=True, timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                pass
            return None, t("mac.e_pas_de_reponse", s=delai)
        try:
            with open(sortie, encoding="utf-8") as f:
                reponse = json.load(f)
            if not isinstance(reponse, dict):
                raise ValueError
        except (OSError, ValueError):
            detail = messages.strip()[-300:]
            return None, t("mac.e_sans_reponse") + ((" (%s)" % detail) if detail else "")
        if not reponse.get("ok"):
            return None, message_erreur(reponse)
        return reponse, None
    finally:
        try:
            os.remove(sortie)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Dates : AAAA-MM-JJ ou AAAA-MM-JJ HH:MM (heure du Mac), ou ISO 8601 avec fuseau

def lire_date(texte):
    """Renvoie (date avec fuseau local, avec_heure) ou (None, False). Une date sans fuseau est l'heure
    locale du Mac, changements d'heure compris."""
    from datetime import datetime
    brut = " ".join(texte.split()).replace("/", "-")
    try:
        d = datetime.fromisoformat(re.sub(r"Z$", "+00:00", brut))
        if not 1970 <= d.year <= 2200:
            return None, False
        return d.astimezone(), len(brut) > 10
    except (ValueError, OverflowError, OSError):
        return None, False


def lisible(d, avec_heure):
    return d.strftime("%Y-%m-%d %H:%M") if avec_heure else d.strftime("%Y-%m-%d")


# ---------------------------------------------------------------------------
# Question à Apple Intelligence (modèle sur le Mac)

def confier_mac(arguments, progression=None):
    consigne = texte_argument(arguments, "consigne")
    if not consigne:
        return t("mcp.consigne_vide"), True
    debut = time.time()

    def faire():
        reponse, erreur = outil_mac(["question", t("mac.consignes_modele"), consigne], delai=45)
        if erreur:
            return erreur, True
        entete = t("mcp.reponse_de", nom=nom("mac"), s=int(time.time() - debut))
        return entete + "\n\n" + (reponse.get("reponse") or t("mcp.reponse_vide")), False
    # Le journal note la question, pas son texte (il peut être personnel).
    return action_mac(t("mac.l_question"), t("mac.l_question"), faire)


# ---------------------------------------------------------------------------
# Rappels

def trouver_liste(nom_liste):
    """Nom exact de la liste demandée (sans casse ni accents, ou nom proche unique).
    Renvoie (nom exact, None) ou (None, message d'erreur avec les listes existantes)."""
    reponse, erreur = outil_mac(["listes"])
    if erreur:
        return None, erreur
    listes = [l.get("nom", "") for l in reponse.get("listes", []) if isinstance(l, dict)]
    cherche = normaliser(nom_liste)
    exactes = [l for l in listes if normaliser(l) == cherche]
    if len(exactes) > 1:
        return None, t("mac.listes_plusieurs", nom=nom_liste, listes=", ".join("« %s »" % l for l in exactes))
    if exactes:
        return exactes[0], None
    contenant = [l for l in listes if cherche and cherche in normaliser(l)]
    if len(contenant) == 1:
        return contenant[0], None
    proches = contenant or [l for l in listes if normaliser(l) in difflib.get_close_matches(
        cherche, [normaliser(x) for x in listes], n=3, cutoff=0.6)]
    texte = t("mac.liste_introuvable", nom=nom_liste)
    if proches:
        texte += " " + t("mac.noms_proches", noms=", ".join("« %s »" % p for p in proches))
    return None, texte + " " + t("mac.listes_existantes", listes=", ".join("« %s »" % l for l in listes) or "—")


def elements_argument(arguments):
    valeur = arguments.get("elements")
    if isinstance(valeur, str):
        valeur = [valeur]
    if not isinstance(valeur, list):
        return []
    return [" ".join(v.split()) for v in valeur if isinstance(v, str) and v.strip()][:50]


def echeance_lisible(texte):
    return (texte or "").strip()


def mac_lire_rappels(arguments):
    nom_liste = texte_argument(arguments, "liste")
    avec_faits = arguments.get("avec_faits") is True
    if not nom_liste:
        reponse, erreur = outil_mac(["listes"])
        if erreur:
            return erreur, True
        lignes = ["- " + t("mac.ligne_liste", nom=l.get("nom"), n=l.get("a_faire"))
                  + (" " + t("mac.par_defaut") if l.get("par_defaut") else "")
                  for l in reponse.get("listes", []) if isinstance(l, dict)]
        return t("mac.listes") + "\n" + ("\n".join(lignes) or t("mac.aucune_liste")), False
    liste, erreur = trouver_liste(nom_liste)
    if erreur:
        return erreur, True
    reponse, erreur = outil_mac(["lire", liste, "1" if avec_faits else "0"])
    if erreur:
        return erreur, True
    elements = [e for e in reponse.get("elements", []) if isinstance(e, dict)]
    if not elements:
        return t("mac.liste_vide" if avec_faits else "mac.liste_rien_a_faire", liste=liste), False
    lignes = []
    for e in elements:
        details = []
        if e.get("echeance"):
            details.append(t("mac.echeance", date=echeance_lisible(e.get("echeance"))))
        note = " ".join(str(e.get("note", "")).split())
        if note:
            details.append(t("mac.note", note=note))
        lignes.append("- [%s] %s%s" % ("x" if e.get("fait") else " ", e.get("nom", ""),
                                       (" (%s)" % " ; ".join(details)) if details else ""))
    a_faire = sum(1 for e in elements if not e.get("fait"))
    entete = t("mac.liste_contenu", liste=liste, n=a_faire)
    if avec_faits:
        entete += t("mac.liste_faits", total=reponse.get("faits_en_tout", 0), montres=len(elements) - a_faire)
    return entete + "\n" + "\n".join(lignes), False


def mac_ajouter_rappels(arguments):
    elements = elements_argument(arguments)
    if not elements:
        return t("mac.ajouter_vide"), True
    liste = ""
    if texte_argument(arguments, "liste"):
        liste, erreur = trouver_liste(texte_argument(arguments, "liste"))
        if erreur:
            return erreur, True
    echeance, quand = "", ""
    brut = texte_argument(arguments, "echeance")
    if brut:
        d, avec_heure = lire_date(brut)
        if d is None:
            return t("mac.date_illisible", texte=brut), True
        echeance = lisible(d, avec_heure)
        quand = " " + t("mac.pour_le", date=echeance)
    resume = ", ".join(elements)

    def faire():
        reponse, erreur = outil_mac(["ajouter", liste, echeance] + elements)
        if erreur:
            return erreur, True
        return t("mac.ajoutes", liste=reponse.get("liste", liste or "?"), elements=resume, quand=quand), False
    return action_mac(t("mac.l_rappels"), t("mac.j_ajoutes", liste=liste or t("mac.liste_par_defaut"),
                                             elements=resume, quand=quand), faire)


def mac_cocher_rappels(arguments):
    nom_liste = texte_argument(arguments, "liste")
    demandes = elements_argument(arguments)
    decocher = arguments.get("decocher") is True
    if not nom_liste or not demandes:
        return t("mac.decocher_vide" if decocher else "mac.cocher_vide"), True
    liste, erreur = trouver_liste(nom_liste)
    if erreur:
        return erreur, True
    reponse, erreur = outil_mac(["lire", liste, "1"])
    if erreur:
        return erreur, True
    # Seule une correspondance exacte (sans casse ni accents) est exécutée ; une correspondance
    # partielle (« Lait » pour « Lait de coco ») est seulement proposée. Doublons : tous cochés.
    par_nom = {}
    for e in reponse.get("elements", []):
        if isinstance(e, dict) and bool(e.get("fait")) == decocher:
            par_nom.setdefault(normaliser(e.get("nom", "")), set()).add(e.get("nom", ""))
    exacts, ecartes = [], []
    for d in demandes:
        n = normaliser(d)
        if n in par_nom:
            exacts += [x for x in sorted(par_nom[n]) if x not in exacts]
            continue
        proches = sorted({v for k, vs in par_nom.items() if n and (n in k or k in n) for v in vs})
        if proches:
            ecartes.append(t("mac.pas_exact", nom=d, proches=", ".join("« %s »" % p for p in proches)))
        elif decocher:
            exacts.append(d)          # peut-être un élément coché il y a longtemps : l'app cherche partout
        else:
            ecartes.append(t("mac.introuvable_a_faire", nom=d))
    verbe = t("mac.decoche" if decocher else "mac.coche")
    if not exacts:
        return t("mac.rien_change", verbe=verbe, liste=liste) + "\n" + "\n".join(ecartes), True

    def faire():
        resultat, erreur = outil_mac(["cocher", liste, "0" if decocher else "1"] + exacts)
        if erreur:
            return erreur, True
        faits = [f for f in resultat.get("faits", []) if isinstance(f, str)]
        ecartes.extend(t("mac.introuvable_coches", nom=f) for f in resultat.get("introuvables", []) if isinstance(f, str))
        resume = ", ".join(("%s (×%d)" % (f, faits.count(f))) if faits.count(f) > 1 else f
                           for f in dict.fromkeys(faits))
        texte = t("mac.coches", verbe=verbe, liste=liste, elements=resume or "—")
        if ecartes:
            texte += "\n" + t("mac.inchanges") + "\n" + "\n".join(ecartes)
        return texte, not faits
    return action_mac(t("mac.l_rappels"), t("mac.coches", verbe=verbe, liste=liste, elements=", ".join(exacts)), faire)


# ---------------------------------------------------------------------------
# Calendrier (écriture seule : YaTeam ne lit jamais l'agenda)

def mac_calendrier(arguments):
    titre = texte_argument(arguments, "titre")
    if not titre:
        return t("mac.titre_vide"), True
    dates = {}
    for cle in ("debut", "fin"):
        brut = texte_argument(arguments, cle)
        d, avec_heure = lire_date(brut) if brut else (None, False)
        if d is None:
            return t("mac.date_manquante_" + cle, texte=brut or "—"), True
        dates[cle] = (d, avec_heure)
    journee = not dates["debut"][1] and not dates["fin"][1]
    # Journée entière : la fin est le dernier jour (compris) ; sinon la fin doit suivre le début.
    if dates["fin"][0] < dates["debut"][0] or (not journee and dates["fin"][0] == dates["debut"][0]):
        return t("mac.fin_avant_debut"), True
    lieu, notes = texte_argument(arguments, "lieu"), texte_argument(arguments, "notes")
    action = t("mac.evenement", titre=titre, debut=lisible(*dates["debut"]), fin=lisible(*dates["fin"]),
               lieu=(" " + t("mac.a_lieu", lieu=lieu)) if lieu else "")

    fin_envoyee = dates["fin"][0]
    if journee:
        from datetime import timedelta
        dernier_jour = fin_envoyee.replace(tzinfo=None)
        fin_envoyee = (dernier_jour + timedelta(days=1) - timedelta(seconds=1)).astimezone()

    def faire():
        reponse, erreur = outil_mac(["evenement", titre, dates["debut"][0].isoformat(timespec="seconds"),
                                     fin_envoyee.isoformat(timespec="seconds"), "1" if journee else "0",
                                     lieu, notes])
        if erreur:
            return erreur, True
        return action + " " + t("mac.dans_calendrier", calendrier=reponse.get("calendrier", "?")), False
    return action_mac(t("mac.l_calendrier"), action, faire)


# ---------------------------------------------------------------------------
# Notes (AppleScript, lancé par YaTeamMac.app : l'autorisation est au nom de « YaTeam Mac »)

def html_simple(texte):
    """Texte → HTML de Notes : caractères spéciaux échappés, une ligne par paragraphe."""
    return "".join("<div>%s</div>" % (html.escape(l) or "<br>") for l in texte.splitlines()) or "<div><br></div>"


def mac_note(arguments):
    titre = " ".join(texte_argument(arguments, "titre").split())
    contenu = texte_argument(arguments, "contenu")
    if not titre or not contenu:
        return t("mac.note_vide"), True
    dossier = texte_argument(arguments, "dossier")
    action = t("mac.note_creee", titre=titre,
               dossier=(" " + t("mac.dans_dossier", dossier=dossier)) if dossier else "")

    def faire():
        # Notes affiche lui-même le titre en première ligne : le corps ne le répète pas.
        _, erreur = outil_mac(["note", titre, html_simple(contenu), dossier])
        return (erreur, True) if erreur else (action, False)
    return action_mac(t("mac.l_note"), action, faire)


# ---------------------------------------------------------------------------
# Ouvrir une app

def apps_installees():
    """Apps du Mac indexées par nom affiché et par nom de fichier (sans casse ni accents), vers
    (nom affiché, chemin). Dictionnaire vide si la liste est illisible."""
    chemins = []
    for dossier in DOSSIERS_APPS:
        try:
            chemins += [os.path.join(dossier, n) for n in sorted(os.listdir(dossier)) if n.endswith(".app")]
        except OSError:
            continue
    if not chemins:
        return {}
    try:
        r = subprocess.run(["/usr/bin/mdls", "-name", "kMDItemDisplayName", "-raw"] + chemins,
                           capture_output=True, timeout=10, env=ENV)
        affiches = r.stdout.decode("utf-8", "replace").split("\0")
        if r.returncode != 0 or len(affiches) != len(chemins):
            affiches = [""] * len(chemins)
    except (OSError, subprocess.TimeoutExpired):
        affiches = [""] * len(chemins)
    apps = {}
    for chemin, affiche in zip(chemins, affiches):
        fichier = os.path.basename(chemin)[:-4]
        affiche = affiche if affiche and affiche != "(null)" else fichier
        if affiche.endswith(".app"):
            affiche = affiche[:-4]
        apps[normaliser(affiche)] = (affiche, chemin)
        apps.setdefault(normaliser(fichier), (affiche, chemin))
    return apps


def mac_ouvrir_app(arguments):
    nom_app = texte_argument(arguments, "nom_app")
    if nom_app.lower().endswith(".app"):
        nom_app = nom_app[:-4].strip()
    if not nom_app:
        return t("mac.app_vide"), True
    apps = apps_installees()
    if normaliser(nom_app) not in apps:
        proches = []
        for cle in difflib.get_close_matches(normaliser(nom_app), list(apps), n=5, cutoff=0.6):
            if apps[cle][0] not in proches:
                proches.append(apps[cle][0])
        conseil = (t("mac.noms_proches", noms=", ".join("« %s »" % p for p in proches[:3])) if proches
                   else t("mac.conseil_applications"))
        return t("mac.app_introuvable", nom=nom_app) + " " + conseil, True
    affiche, chemin = apps[normaliser(nom_app)]

    def faire():
        try:
            r = subprocess.run(["/usr/bin/open", chemin], capture_output=True, text=True, timeout=20, env=ENV)
        except subprocess.TimeoutExpired:
            return t("mac.e_app_delai", nom=affiche), True
        if r.returncode != 0:
            return t("mac.e_app", nom=affiche, detail=r.stderr.strip()[-300:] or "open"), True
        return t("mac.app_ouverte", nom=affiche), False
    return action_mac(t("mac.l_app"), t("mac.app_ouverte", nom=affiche), faire)
