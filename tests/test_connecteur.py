"""Faux client MCP (stdio) pour tester le connecteur installé, sans l'app Claude.

À lancer par tests/lancer_tests.sh, avec HOME = un dossier personnel de test et les faux
programmes (tests/faux) dans PATH : aucun vrai codex, agy ni claude n'est appelé.

  test_connecteur.py complet                    tous les échanges (en français, noms Pesto et Nori)
  test_connecteur.py outils <outil> [<outil>…]  vérifie seulement la liste des outils
  test_connecteur.py langue <mot> <mot>         instructions et erreurs dans la langue installée
  test_connecteur.py mac <surnom du Mac>        membre Mac (faux YaTeamMac, faux Raccourcis), noms Pesto et Nori
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

MAISON = os.path.expanduser("~")
CONNECTEUR = os.path.join(MAISON, ".claude", "equipe", "mcp_equipe.py")
echecs = []


def verifier(condition, message):
    print(("  ✓ " if condition else "  ✗ ") + message)
    if not condition:
        echecs.append(message)


class Client:
    def __init__(self, attente_max="4"):
        env = dict(os.environ, EQUIPE_ATTENTE_MAX=attente_max)
        self.p = subprocess.Popen(["/usr/bin/python3", "-I", CONNECTEUR], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.messages = queue.Queue()
        threading.Thread(target=self._lire, daemon=True).start()
        self.n = 0

    def _lire(self):
        for ligne in self.p.stdout:
            self.messages.put(json.loads(ligne))

    def brut(self, texte):
        self.p.stdin.write(texte + "\n")
        self.p.stdin.flush()

    def envoyer(self, methode, params=None, identifiant=None):
        self.n += 1
        ident = self.n if identifiant is None else identifiant
        message = {"jsonrpc": "2.0", "id": ident, "method": methode}
        if params is not None:
            message["params"] = params
        self.brut(json.dumps(message))
        return ident

    def recevoir(self, delai=30):
        return self.messages.get(timeout=delai)

    def demander(self, methode, params=None, delai=30):
        ident = self.envoyer(methode, params)
        fin = time.time() + delai
        while time.time() < fin:
            m = self.recevoir(max(0.1, fin - time.time()))
            if m.get("id") == ident:
                return m
        raise TimeoutError(methode)

    def outil(self, nom, arguments, delai=30):
        return self.demander("tools/call", {"name": nom, "arguments": arguments}, delai)

    def fermer(self):
        self.p.stdin.close()
        self.p.wait(10)


def texte(reponse):
    return " ".join(c.get("text", "") for c in reponse["result"]["content"] if c.get("type") == "text")


def liste_outils(client):
    client.demander("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                   "clientInfo": {"name": "test", "version": "1"}})
    return sorted(o["name"] for o in client.demander("tools/list")["result"]["tools"])


def test_outils(attendus):
    c = Client()
    noms = liste_outils(c)
    c.fermer()
    verifier(noms == sorted(attendus), "outils annoncés %s (attendu %s)" % (noms, sorted(attendus)))


def test_langue(mot_instructions, mot_erreur):
    """Langue choisie : instructions et messages d'erreur traduits."""
    c = Client()
    r = c.demander("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "test", "version": "1"}})
    verifier(mot_instructions in r["result"]["instructions"], "instructions traduites (« %s »)" % mot_instructions)
    outils = c.demander("tools/list")["result"]["tools"]
    confier = next(o for o in outils if o["name"].startswith("confier_a_"))
    r = c.outil(confier["name"], {"consigne": " "})
    verifier(r["result"]["isError"] and mot_erreur in texte(r), "erreur traduite (« %s »)" % mot_erreur)
    c.fermer()


def test_complet():
    c = Client()
    print("Protocole")
    r = c.demander("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "test", "version": "1"}})
    resultat = r.get("result", {})
    verifier(resultat.get("protocolVersion") == "2025-06-18", "initialize : version demandée reprise")
    verifier(resultat.get("serverInfo", {}).get("name") == "equipe", "initialize : nom du serveur")
    instructions = resultat.get("instructions", "")
    verifier("Pesto" in instructions and "Nori" in instructions, "initialize : instructions avec les noms")
    verifier(c.demander("initialize", {"protocolVersion": "1999-01-01"})["result"]["protocolVersion"] == "2025-11-25",
             "initialize : version inconnue → la plus récente")
    c.brut(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}))
    verifier(c.demander("ping")["result"] == {}, "ping, et la notification n'a reçu aucune réponse")
    outils = sorted(o["name"] for o in c.demander("tools/list")["result"]["tools"])
    verifier(outils == ["attendre_reponse", "confier_a_nori", "confier_a_pesto", "faire_une_image", "quotas_equipe"],
             "tools/list : %s" % outils)

    print("Messages invalides")
    c.brut("{ceci n'est pas du JSON")
    m = c.recevoir()
    verifier(m.get("error", {}).get("code") == -32700 and m.get("id") is None, "JSON illisible → -32700")
    c.brut("[]")
    verifier(c.recevoir().get("error", {}).get("code") == -32600, "lot vide → -32600")
    c.brut(json.dumps([{"jsonrpc": "2.0", "id": "a", "method": "ping"}, {"jsonrpc": "2.0", "id": "b", "method": "ping"}]))
    ids = sorted([c.recevoir()["id"], c.recevoir()["id"]])
    verifier(ids == ["a", "b"], "lot de deux ping → deux réponses")
    verifier(c.demander("methode/inconnue").get("error", {}).get("code") == -32601, "méthode inconnue → -32601")
    c.brut(json.dumps({"jsonrpc": "2.0", "id": 900, "method": 42}))
    verifier(c.recevoir().get("error", {}).get("code") == -32600, "méthode qui n'est pas un texte → -32600")
    verifier(c.demander("tools/call", {"name": "confier_a_pesto", "arguments": "texte"}).get("error", {}).get("code")
             == -32602, "arguments qui ne sont pas un objet → -32602")
    verifier(c.outil("outil_imaginaire", {}).get("error", {}).get("code") == -32602, "outil inconnu → -32602")

    print("Appels en erreur")
    r = c.outil("confier_a_pesto", {"consigne": "   "})
    verifier(r["result"]["isError"] and "Consigne vide" in texte(r), "consigne vide refusée")
    r = c.outil("confier_a_nori", {"consigne": "Bonjour", "dossier": "/dossier/qui/n/existe/pas"})
    verifier(r["result"]["isError"] and "introuvable" in texte(r), "dossier inexistant refusé")
    r = c.outil("attendre_reponse", {"tache": "pesto-000000000000"})
    verifier(r["result"]["isError"] and "inconnue" in texte(r), "tâche inconnue signalée")
    r = c.outil("attendre_reponse", {})
    verifier(r["result"]["isError"], "attendre_reponse sans numéro refusé")
    for destination, cas in [("/tmp", "hors du dossier personnel"), ("~/.cache/images", "dossier caché"),
                             ("~/Library/Images", "Bibliothèque"), ("~", "racine du dossier personnel"), ("", "vide")]:
        r = c.outil("faire_une_image", {"description": "un chat", "destination": destination})
        verifier(r["result"]["isError"] and "refusée" in texte(r), "image : destination refusée (%s)" % cas)
    r = c.outil("faire_une_image", {"description": " ", "destination": "~/Images-test"})
    verifier(r["result"]["isError"] and "Description vide" in texte(r), "image : description vide refusée")
    r = c.outil("confier_a_pesto", {"consigne": "Provoque un ÉCHEC", "dossier": MAISON})
    verifier(r["result"]["isError"] and "n'a pas pu répondre" in texte(r) and "quota épuisé" in texte(r),
             "échec de Codex rapporté avec la fin de son journal")

    print("Tâches")
    r = c.outil("confier_a_pesto", {"consigne": "Dis bonjour", "dossier": MAISON})
    verifier(not r["result"]["isError"] and "Réponse de Pesto" in texte(r) and "Réponse factice de Codex" in texte(r),
             "Pesto répond (faux Codex, lecture seule vérifiée)")
    with open(os.path.join(MAISON, ".claude", "equipe", "etat", "codex.json"), encoding="utf-8") as f:
        verifier(json.load(f).get("au_travail") is False, "état d'activité de Pesto revenu à « libre »")
    r = c.outil("confier_a_nori", {"consigne": "Résume ce dossier", "dossier": MAISON, "attendre": False})
    numero = texte(r).split("Tâche n° ")[-1].split(" ")[0]
    verifier(not r["result"]["isError"] and numero.startswith("antigravity-"), "tâche confiée sans attendre : %s" % numero)
    r = c.outil("attendre_reponse", {"tache": numero})
    verifier("Réponse de Nori" in texte(r) and "Résume ce dossier" in texte(r), "attendre_reponse rend la réponse de Nori")
    r = c.outil("confier_a_pesto", {"consigne": "Tâche LENT", "dossier": MAISON})
    verifier("travaille encore" in texte(r) and not r["result"]["isError"], "tâche longue : numéro rendu au bout du délai")
    numero = texte(r).split("Tâche n° ")[-1].split(" ")[0]
    for _ in range(4):
        r = c.outil("attendre_reponse", {"tache": numero})
        if "Réponse de Pesto" in texte(r):
            break
    verifier("Réponse de Pesto" in texte(r), "tâche longue : réponse récupérée ensuite")

    print("Images")
    r = c.outil("faire_une_image", {"description": "un chat en peluche", "destination": "~/Images-test",
                                    "nom": "chat", "variantes": 1.0})
    cible = os.path.join(MAISON, "Images-test", "chat.png")
    images = [x for x in r["result"]["content"] if x.get("type") == "image"]
    verifier(not r["result"]["isError"] and os.path.isfile(cible), "image rangée dans %s" % cible)
    verifier(len(images) == 1 and images[0]["mimeType"] == "image/jpeg", "aperçu joint à la réponse")
    r = c.outil("faire_une_image", {"description": "un autre chat", "destination": "~/Images-test", "nom": "chat"})
    verifier(os.path.isfile(os.path.join(MAISON, "Images-test", "chat (2).png")), "jamais d'écrasement : chat (2).png")
    r = c.outil("faire_une_image", {"description": "un robot", "destination": "~/Images-test", "nom": "robot",
                                    "auteur": "pesto"})
    verifier(not r["result"]["isError"] and os.path.isfile(os.path.join(MAISON, "Images-test", "robot.png")),
             "image de Pesto (Codex) retrouvée par sa session et rangée")
    r = c.outil("faire_une_image", {"description": "un robot", "destination": "~/Images-test", "auteur": "inconnu"})
    verifier(r["result"]["isError"] and "Auteur inconnu" in texte(r), "auteur d'image inconnu refusé")

    print("Quotas")
    r = c.outil("quotas_equipe", {}, delai=60)
    t = texte(r)
    verifier("42 %" in t and "17 %" in t, "quota de Claude (faux /usage)")
    verifier("12 %" in t and "Pesto" in t, "quota de Pesto (compteurs de Codex)")
    verifier("25 %" in t and "Nori" in t, "quota de Nori (faux /quota)")
    c.fermer()


def test_mac(surnom):
    """Membre Mac : outils, Rappels (faux YaTeamMac), Calendrier, question, note, journal ; il ne dessine pas."""
    c = Client(attente_max="10")
    noms = liste_outils(c)
    outil = "confier_a_" + surnom.lower()
    attendus = {outil, "mac_lire_rappels", "mac_ajouter_rappels", "mac_cocher_rappels", "mac_calendrier", "mac_note",
                "mac_ouvrir_app", "mac_lire_journal"}
    verifier(attendus <= set(noms), "outils du Mac annoncés (%s)" % ", ".join(sorted(attendus - set(noms))) or "tous")
    instructions = c.demander("initialize", {"protocolVersion": "2025-06-18"})["result"]["instructions"]
    verifier(surnom in instructions and "mac_lire_rappels" in instructions and "invitation" in instructions,
             "instructions : le Mac est présenté, sans message ni invitation")
    r = c.outil("mac_lire_rappels", {})
    verifier("Courses : 2 à faire" in texte(r) and "(liste par défaut)" in texte(r), "listes de Rappels lues")
    r = c.outil("mac_lire_rappels", {"liste": "courses"})
    verifier("[ ] Lait" in texte(r) and "Pain" not in texte(r), "liste trouvée sans casse, éléments à faire seulement")
    r = c.outil("mac_ajouter_rappels", {"elements": ["Beurre", "Œufs"], "liste": "Courses", "echeance": "2026-12-01 18:30"})
    verifier(not r["result"]["isError"] and "Beurre, Œufs" in texte(r) and "2026-12-01 18:30" in texte(r),
             "éléments ajoutés avec échéance")
    r = c.outil("mac_ajouter_rappels", {"elements": ["Appeler le plombier"]})
    verifier(not r["result"]["isError"] and "Courses" in texte(r), "sans liste : liste par défaut")
    r = c.outil("mac_ajouter_rappels", {"elements": ["x"], "echeance": "demain"})
    verifier(r["result"]["isError"] and "illisible" in texte(r), "échéance illisible refusée")
    r = c.outil("mac_ajouter_rappels", {"elements": ["x"], "liste": "Vacances"})
    verifier(r["result"]["isError"] and "Listes existantes" in texte(r), "liste inconnue : listes existantes proposées")
    r = c.outil("mac_cocher_rappels", {"liste": "Courses", "elements": ["lait"]})
    verifier(not r["result"]["isError"] and "coché : Lait." in texte(r) and "Lait de coco" not in texte(r),
             "seul le nom exact est coché (« Lait », pas « Lait de coco »)")
    r = c.outil("mac_cocher_rappels", {"liste": "Courses", "elements": ["coco"]})
    verifier(r["result"]["isError"] and "proches" in texte(r), "nom seulement proche : proposé, rien coché")
    r = c.outil("mac_calendrier", {"titre": "Montage", "debut": "2026-12-03 08:00", "fin": "2026-12-03 18:00",
                                   "lieu": "Lyon"})
    verifier(not r["result"]["isError"] and "Montage" in texte(r) and "Lyon" in texte(r), "événement créé")
    r = c.outil("mac_calendrier", {"titre": "Festival", "debut": "2026-12-05", "fin": "2026-12-05"})
    verifier(not r["result"]["isError"], "journée entière : fin = dernier jour accepté")
    r = c.outil("mac_calendrier", {"titre": "X", "debut": "2026-12-03 18:00", "fin": "2026-12-03 08:00"})
    verifier(r["result"]["isError"] and "après le début" in texte(r), "fin avant le début refusée")
    r = c.outil(outil, {"consigne": "Reformule : bonjour"})
    verifier(not r["result"]["isError"] and "Réponse factice du modèle du Mac" in texte(r), "question à Apple Intelligence")
    r = c.outil("faire_une_image", {"description": "un soleil", "destination": "~/Images-test", "auteur": surnom.lower()})
    verifier(r["result"]["isError"] and "Auteur inconnu" in texte(r), "le Mac n'est pas auteur d'images")
    r = c.outil("mac_note", {"titre": "Idées", "contenu": "Ligne 1\nLigne 2"})
    verifier(not r["result"]["isError"] and "Note créée" in texte(r), "note créée par l'app du Mac")
    r = c.outil("mac_note", {"titre": "Idées", "contenu": "x", "dossier": "Inconnu"})
    verifier(r["result"]["isError"] and "Inconnu" in texte(r), "dossier de Notes inconnu : rien n'est créé")
    r = c.outil("mac_ouvrir_app", {"nom_app": "Application Qui N Existe Pas"})
    verifier(r["result"]["isError"] and "rien n'a été ouvert" in texte(r), "app inconnue : rien n'est ouvert")
    r = c.outil("mac_lire_journal", {})
    journal = texte(r)
    verifier("Beurre" in journal and "Montage" in journal and "Note créée" in journal
             and "Question à Apple Intelligence" in journal and "Reformule" not in journal,
             "journal du Mac : actions réussies notées, sans le texte des questions")
    with open(os.path.join(MAISON, ".claude", "equipe", "etat", "mac.json"), encoding="utf-8") as f:
        etat = json.load(f)
    verifier(etat.get("au_travail") is False and etat.get("actions_jour", 0) >= 5, "état du Mac pour le panneau")
    r = c.outil("quotas_equipe", {}, delai=60)
    verifier(surnom in texte(r) and "aucun quota" in texte(r), "quotas : ligne du Mac")
    c.fermer()


if __name__ == "__main__":
    if not os.path.isfile(CONNECTEUR):
        sys.exit("Connecteur non installé dans %s" % CONNECTEUR)
    if sys.argv[1:2] == ["outils"]:
        test_outils(sys.argv[2:])
    elif sys.argv[1:2] == ["langue"]:
        test_langue(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["mac"]:
        test_mac(sys.argv[2])
    else:
        test_complet()
    if echecs:
        print("%d échec(s)" % len(echecs))
        sys.exit(1)
