"""Noyau du connecteur de YaTeam : réglages, membres de l'équipe, textes, tâches.

Partagé par mcp_equipe.py (le connecteur) et ses modules garde.py, mac.py et images.py.
Python 3.9, sans dépendance. Les modules sont chargés depuis ~/.claude/equipe (le dossier du
connecteur est ajouté au chemin des modules, car le connecteur est lancé avec python3 -I).
"""
import base64
import fcntl
import json
import os
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import uuid

from textes import Textes

MAISON = os.path.expanduser("~")
EQUIPE = os.path.join(MAISON, ".claude", "equipe")
ATELIER = os.path.join(EQUIPE, "atelier")
ETAT = os.path.join(EQUIPE, "etat")
CONFIG = os.path.join(EQUIPE, "config.json")
ATTENTE_MAX = int(os.environ.get("EQUIPE_ATTENTE_MAX", "50"))   # s d'attente par appel (< 60 s de l'app)
DUREE_MAX = 15 * 60       # une tâche est arrêtée au bout de 15 minutes
GARDE_RESULTATS = 3600    # une réponse non relevée est oubliée au bout d'une heure
# Surnoms de secours, si config.json n'en donne pas (install.sh les tire au hasard).
DEFAUTS = {"codex": "Pesto", "antigravity": "Praline", "mac": "Nougat"}

ENV = dict(os.environ)
# L'app Claude lance les connecteurs avec un environnement réduit : Claude Code a besoin
# de USER pour retrouver sa connexion dans le trousseau (sinon /usage ne répond rien).
_compte = pwd.getpwuid(os.getuid()).pw_name
ENV.setdefault("USER", _compte)
ENV.setdefault("LOGNAME", _compte)
ENV.setdefault("TMPDIR", tempfile.gettempdir())


# ---------------------------------------------------------------------------
# Petits fichiers JSON

def lire_json(chemin):
    try:
        with open(chemin, encoding="utf-8") as f:
            contenu = json.load(f)
        return contenu if isinstance(contenu, dict) else {}
    except (OSError, ValueError):
        return {}


def mettre_a_jour_json(chemin, modifier):
    """Lit, modifie et réécrit un petit fichier d'état sous verrou de fichier (plusieurs
    connecteurs tournent à la fois, un par conversation), avec un fichier temporaire unique
    et un renommage atomique. Ne lève jamais d'erreur : l'état n'est qu'un affichage."""
    try:
        os.makedirs(os.path.dirname(chemin), exist_ok=True)
        with open(chemin + ".verrou", "a") as verrou:
            fcntl.flock(verrou, fcntl.LOCK_EX)
            etat = lire_json(chemin)
            modifier(etat)
            provisoire = "%s.%d.%s.tmp" % (chemin, os.getpid(), uuid.uuid4().hex[:8])
            with open(provisoire, "w", encoding="utf-8") as f:
                json.dump(etat, f, ensure_ascii=False)
            os.replace(provisoire, chemin)
    except Exception as erreur:
        journal("état %s non écrit : %s" % (os.path.basename(chemin), erreur))


# ---------------------------------------------------------------------------
# Réglages (~/.claude/equipe/config.json, écrit par install.sh) : langue, surnoms et activation
# des membres, chemins des programmes relevés à l'installation.

REGLAGES = lire_json(CONFIG)
t = Textes(REGLAGES.get("langue"))
_programmes = REGLAGES.get("programmes") if isinstance(REGLAGES.get("programmes"), dict) else {}
PROGRAMMES = {cle: chemin for cle, chemin in _programmes.items()
              if isinstance(chemin, str) and os.path.isabs(chemin) and os.access(chemin, os.X_OK)}


def programme(nom_programme):
    """Chemin relevé à l'installation (Homebrew, nvm, npm…), sinon le nom, cherché dans PATH."""
    return PROGRAMMES.get(nom_programme, nom_programme)


# L'app Claude lance les connecteurs sans le PATH du Terminal : on y ajoute les dossiers des
# programmes relevés (node est souvent rangé à côté) et les dossiers d'installation habituels.
_dossiers = [os.path.dirname(c) for c in PROGRAMMES.values()]
ENV["PATH"] = ":".join(dict.fromkeys(_dossiers + ["/opt/homebrew/bin", "/usr/local/bin",
                                                  os.path.join(MAISON, ".local", "bin"),
                                                  ENV.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")]))

# ---------------------------------------------------------------------------
# Les membres de l'équipe (en plus de Claude, le chef de projet)

MOTEURS = {
    "codex": {"programme": "codex", "ia": "ChatGPT", "dessine": True},
    "antigravity": {"programme": "agy", "ia": "Gemini", "dessine": True},
    # Le Mac : YaTeamMac.app (Rappels, Calendrier, Notes, Apple Intelligence), lancée par `open`. Pas d'images.
    "mac": {"programme": "/usr/bin/open", "ia": "Apple Intelligence", "dessine": False},
}
ORDRE = ("antigravity", "codex", "mac")


def identifiant(nom_membre, separateur="_"):
    """« Léa Martin » → « lea_martin » (noms d'outils MCP et d'agents)."""
    ascii_ = unicodedata.normalize("NFKD", nom_membre).encode("ascii", "ignore").decode("ascii").lower()
    return re.sub(r"[^a-z0-9]+", separateur, ascii_).strip(separateur)[:40]


def lire_membres():
    reglages = REGLAGES.get("membres")
    reglages = reglages if isinstance(reglages, dict) else {}
    membres = {}
    for cle, moteur in MOTEURS.items():
        r = reglages.get(cle) if isinstance(reglages.get(cle), dict) else {}
        nom_lu = r.get("nom") if isinstance(r.get("nom"), str) and r.get("nom").strip() else DEFAUTS[cle]
        # Un réglage d'avant la version 2 ne connaît pas le Mac : il reste éteint tant qu'on ne l'a pas choisi.
        actif_par_defaut = cle != "mac"
        membres[cle] = dict(moteur, nom=" ".join(nom_lu.split())[:30],
                            actif=r.get("actif", actif_par_defaut) is True)
        if cle == "mac":
            # Relevé à l'installation par YaTeamMac.app : Apple Intelligence (questions).
            membres[cle].update(question=r.get("apple_intelligence") is True)
    # Identifiant de chaque membre (outil « confier_a_<identifiant> », auteur d'image) ; repli sur
    # la clé interne en cas de doublon ou de nom illisible.
    slugs = {cle: identifiant(m["nom"]) for cle, m in membres.items()}
    finals = {cle: (slug if slug and list(slugs.values()).count(slug) == 1 else cle) for cle, slug in slugs.items()}
    if len(set(finals.values())) < len(finals):        # ex. un surnom égal à la clé d'un autre membre
        finals = {cle: cle for cle in membres}
    for cle, m in membres.items():
        m["slug"] = finals[cle]
        m["outil"] = "confier_a_" + finals[cle]
    return membres


MEMBRES = lire_membres()
ACTIFS = [cle for cle in ORDRE if MEMBRES[cle]["actif"]]


def nom(cle):
    return MEMBRES[cle]["nom"]


def enumerer(elements, liaison="commun.et"):
    """[a, b, c] → « a, b et c » dans la langue choisie."""
    elements = list(elements)
    if len(elements) <= 1:
        return "".join(elements)
    return t("commun.virgule").join(elements[:-1]) + t(liaison) + elements[-1]


# ---------------------------------------------------------------------------
# Échanges JSON-RPC (sortie standard) et journal (erreur standard)

verrou_sortie = threading.Lock()


def envoyer(message):
    ligne = json.dumps(message, ensure_ascii=False)
    with verrou_sortie:
        sys.stdout.write(ligne + "\n")
        sys.stdout.flush()


def journal(texte):
    sys.stderr.write("[equipe] %s\n" % texte)
    sys.stderr.flush()


class Progression:
    """Notifications de progression pendant une attente (si le client en a demandé)."""

    def __init__(self, params):
        meta = params.get("_meta") if isinstance(params, dict) else None
        self.jeton = meta.get("progressToken") if isinstance(meta, dict) else None
        self.compte = 0

    def signaler(self, message):
        if self.jeton is None:
            return
        self.compte += 1
        envoyer({"jsonrpc": "2.0", "method": "notifications/progress",
                 "params": {"progressToken": self.jeton, "progress": self.compte, "message": message}})


# ---------------------------------------------------------------------------
# Processus

def arreter_groupe(processus):
    """Arrête tout le groupe de processus (et ses descendants), même si le processus principal
    est déjà fini, puis le récolte."""
    if processus is None:
        return
    for sig, pause in ((signal.SIGTERM, 2), (signal.SIGKILL, 0)):
        try:
            os.killpg(processus.pid, sig)
        except (ProcessLookupError, PermissionError):
            break
        except Exception:
            pass
        time.sleep(pause)
    try:
        processus.wait(5)
    except Exception:
        pass


def processus_vivant(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return True


# ---------------------------------------------------------------------------
# Tâches : une réponse longue ne bloque pas (numéro de tâche à passer à attendre_reponse)

taches = {}
verrou_taches = threading.Lock()


def enregistrer(tache):
    with verrou_taches:
        for vieux in [n for n, x in taches.items() if x.fin and time.time() - x.fin > GARDE_RESULTATS]:
            del taches[vieux]
        taches[tache.id] = tache


class Tache:
    """Une tâche confiée à un membre. Par défaut : le script ~/.claude/equipe/<membre>.sh, consigne
    sur l'entrée standard ; les tâches du Mac (raccourcis) redéfinissent `_travailler`."""

    def __init__(self, membre, consigne=None, dossier=None, apres=None, apres_toujours=False):
        self.id = "%s-%s" % (membre, uuid.uuid4().hex[:12])
        self.membre = membre
        self.debut = time.time()
        self.fini = threading.Event()
        self.reponse = ""
        self.code = None
        self.fin = None
        self.apres = apres                      # traitement une fois la réponse reçue (ex. ranger des images)
        self.apres_toujours = apres_toujours    # même si le script a échoué (images : diagnostic d'erreur)
        self.images = []                        # contenus MCP « image » (aperçus) à joindre à la réponse
        self.processus = None
        if consigne is not None:
            script = os.path.join(EQUIPE, membre + ".sh")
            # Groupe de processus à part : un arrêt emporte aussi codex/agy lancés par le script.
            self.processus = subprocess.Popen([script, dossier], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                              stderr=subprocess.STDOUT, env=ENV, cwd=dossier, text=True,
                                              errors="replace", start_new_session=True)
            threading.Thread(target=self._suivre, args=(consigne,), daemon=True).start()

    def _suivre(self, consigne):
        try:
            sortie, _ = self.processus.communicate(consigne, timeout=DUREE_MAX)
            self.reponse = (sortie or "").strip()
            self.code = self.processus.returncode
        except subprocess.TimeoutExpired:
            self.arreter()
            self.reponse = t("mcp.delai_depasse", nom=nom(self.membre))
            self.code = -1
        except BaseException as erreur:
            self.arreter()
            self.reponse = t("mcp.interrompue", nom=nom(self.membre), erreur=erreur)
            self.code = -1
        if self.apres and (self.code == 0 or self.apres_toujours):
            try:
                self.reponse, self.images, erreur = self.apres(self.reponse)
                if erreur:
                    self.code = -1
            except Exception as erreur:
                self.reponse = t("mcp.rangement_impossible", erreur=erreur) + "\n\n" + self.reponse
                self.code = -1
        self.terminer()

    def terminer(self):
        self.fin = time.time()
        self.fini.set()

    def arreter(self):
        """Arrête tout le groupe (script + codex/agy, ou raccourci) et récolte le processus."""
        arreter_groupe(self.processus) if self.processus is not None else None

    def attendre(self, progression, depuis=None):
        limite = (depuis or time.time()) + ATTENTE_MAX
        while not self.fini.wait(timeout=min(10, max(0.1, limite - time.time()))):
            if time.time() >= limite:
                return False
            progression.signaler(t("mcp.progression", nom=nom(self.membre), s=int(time.time() - self.debut)))
        return True

    def resultat(self):
        entete = t("mcp.reponse_de", nom=nom(self.membre), s=int(time.time() - self.debut))
        return entete + "\n\n" + (self.reponse or t("mcp.reponse_vide")), self.code != 0, self.images

    def en_cours(self):
        return t("mcp.en_cours", nom=nom(self.membre), s=int(time.time() - self.debut), tache=self.id)


def attendre_ou_numero(tache, progression, depuis=None):
    """La réponse si elle arrive dans le délai de l'outil, sinon le numéro de tâche."""
    if tache.attendre(progression, depuis):
        return tache.resultat()
    return tache.en_cours(), False


# ---------------------------------------------------------------------------
# Fichiers d'images rangés par Claude

def dossier_autorise(chemin):
    """Dossier de rangement choisi par Claude : sous le dossier personnel, hors dossiers
    cachés et Bibliothèque (pas de réglages ni de données d'apps)."""
    if not chemin.strip():
        return None, t("mcp.dest_vide")
    chemin = os.path.realpath(os.path.expanduser(chemin.strip()))
    relatif = os.path.relpath(chemin, os.path.realpath(MAISON))
    if relatif.startswith("..") or relatif == ".":
        return None, t("mcp.dest_hors_maison", maison=MAISON)
    morceaux = relatif.split(os.sep)
    if any(m.startswith(".") for m in morceaux) or morceaux[0] == "Library":
        return None, t("mcp.dest_cache")
    return chemin, None


def nom_de_fichier(nom_voulu, auteur):
    nom_voulu = re.sub(r"[/\\:\x00-\x1f]", "-", (nom_voulu or "").strip()).strip(" .-")[:60]
    return nom_voulu or time.strftime("image-%s-%%Y%%m%%d-%%H%%M" % auteur)


def apercu(chemin):
    """Aperçu réduit (512 px) en base64, pour que Claude voie l'image sans la charger en entier."""
    tmp = os.path.join(tempfile.gettempdir(), "equipe-apercu-%s.jpg" % uuid.uuid4().hex[:8])
    try:
        subprocess.run(["/usr/bin/sips", "-Z", "512", "-s", "format", "jpeg", chemin, "--out", tmp],
                       capture_output=True, timeout=30, check=True)
        with open(tmp, "rb") as f:
            return {"type": "image", "data": base64.b64encode(f.read()).decode("ascii"), "mimeType": "image/jpeg"}
    except Exception:
        return None
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def copier_images(sources, destination, nom_fichier):
    """Copie les images dans `destination`, sans jamais écraser un fichier existant, même entre
    deux tâches simultanées (création exclusive). Un fichier : « nom » ; plusieurs : nom, nom-2…
    Renvoie (chemins rangés, aperçus)."""
    os.makedirs(destination, exist_ok=True)
    ranges, apercus = [], []
    for i, source in enumerate(sources):
        extension = os.path.splitext(source)[1].lower() or ".png"
        base = nom_fichier if i == 0 else "%s-%d" % (nom_fichier, i + 1)
        cible = os.path.join(destination, base + extension)
        n = 2
        while True:
            try:
                with open(source, "rb") as lu, open(cible, "xb") as ecrit:
                    shutil.copyfileobj(lu, ecrit)
                break
            except FileExistsError:
                cible = os.path.join(destination, "%s (%d)%s" % (base, n, extension))
                n += 1
        shutil.copystat(source, cible)
        ranges.append(cible)
        a = apercu(cible)
        if a:
            apercus.append(a)
    return ranges, apercus


def normaliser(texte):
    """Sans accents ni casse, pour comparer des noms (apps, listes de Rappels)."""
    sans_accents = "".join(c for c in unicodedata.normalize("NFD", texte) if not unicodedata.combining(c))
    return sans_accents.casefold().strip()


def texte_argument(arguments, cle):
    valeur = arguments.get(cle)
    return valeur.strip() if isinstance(valeur, str) else ""


# ---------------------------------------------------------------------------
# Heures

def heure_locale(date_epoch):
    h = time.localtime(date_epoch + 30)   # arrondi à la minute
    return t("commun.heure", h=h.tm_hour, m="%02d" % h.tm_min)


def remise(date_epoch):
    """« remise à zéro dans 2 h 05 », « … jeu. 18h00 », « pas entamée »."""
    if date_epoch is None:
        return t("mcp.q_pas_entamee")
    reste = date_epoch - time.time()
    if reste <= 0:
        return t("mcp.q_remise_passee")
    if reste < 24 * 3600:
        return t("mcp.q_remise_dans", h=int(reste // 3600), m="%02d" % ((reste % 3600) // 60))
    jour = t.liste("commun.jours")[time.localtime(date_epoch + 30).tm_wday]
    return t("mcp.q_remise_le", jour=jour, heure=heure_locale(date_epoch))


def date_courte(date_epoch):
    d = time.localtime(date_epoch)
    return t("commun.date_courte", j=d.tm_mday, mo="%02d" % d.tm_mon, heure=heure_locale(date_epoch))
