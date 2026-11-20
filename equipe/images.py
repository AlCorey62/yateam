"""Images de YaTeam : faire_une_image, avec deux auteurs possibles.

- Gemini (Antigravity) : outil generate_image ; antigravity.sh signale les fichiers par des lignes
  « [[image]] <chemin> ».
- ChatGPT (Codex) : outil d'image de Codex, qui garde l'image dans ~/.codex/generated_images/<session>/.
  C'est le connecteur, pas le membre (lecture seule), qui retrouve la session de la tâche grâce à une
  référence unique écrite dans la consigne, puis copie le fichier. Jamais de repli « par date » : ce
  pourrait être l'image d'une autre tâche lancée en même temps.
Le Mac ne dessine pas : Image Playground refuse de dessiner pour les apps (« notSupported » sur macOS 27).
Les erreurs (quota, filtre de contenu, aucun fichier) sont rendues avec le message d'origine ; la
dernière erreur de quota d'images de chacun est gardée dans etat/quotas-images.json.
"""
import json
import os
import re
import time
import uuid

from noyau import (ACTIFS, ATELIER, ATTENTE_MAX, ETAT, MAISON, MEMBRES, Tache, attendre_ou_numero, copier_images,
                   date_courte, dossier_autorise, enregistrer, journal, lire_json, mettre_a_jour_json, nom,
                   nom_de_fichier, remise, t)

ETAT_QUOTAS_IMAGES = os.path.join(ETAT, "quotas-images.json")
IMAGES_CODEX = os.path.join(MAISON, ".codex", "generated_images")
SESSIONS_CODEX = os.path.join(MAISON, ".codex", "sessions")
EXTENSIONS_IMAGES = (".png", ".jpg", ".jpeg", ".webp", ".heic")
DELAI_IMAGE_MAC = 120    # s par image (Image Playground est plus lent)

MOTIF_QUOTA = re.compile(r"quota|rate.?limit|usage limit|resource_exhausted|\b429\b|too many requests|"
                         r"(?:daily|generation) limit|limite (?:d.utilisation|quotidienne|de génération)|"
                         r"Kontingent|Limit erreicht|cuota|límite de uso|limite di utilizzo|上限|配额|限额", re.I)
MOTIF_FILTRE = re.compile(r"content.?polic|safety|moderation|usage polic|policy violation|violat\w* (?:of )?"
                          r"(?:our |the )?polic|inappropri|disallowed|not allowed|filtre de contenu|"
                          r"règles? (?:de sécurité|d.utilisation|de contenu)|contenu (?:sensible|inapproprié|interdit)|"
                          r"Inhaltsrichtlinie|política de contenido|norme sui contenuti|コンテンツポリシー|内容政策", re.I)


def auteurs_images():
    """Membres actifs qui savent dessiner, dans l'ordre de préférence (le premier est l'auteur par défaut)."""
    return [c for c in ACTIFS if MEMBRES[c].get("dessine")]


# ---------------------------------------------------------------------------
# Erreurs d'images : jamais masquées, quota mémorisé

def remise_a_zero(texte):
    """Heure de remise à zéro (epoch) lue dans un message d'erreur, ou None si elle n'y est pas."""
    def duree(morceau):
        total = 0
        for valeur, unite in re.findall(r"(\d+)\s*(heures?|hours?|h|minutes?|min|m|secondes?|seconds?|sec|s)"
                                        r"(?![a-zé])", morceau, re.I):
            u = unite.lower()
            total += int(valeur) * (3600 if u.startswith("h") else 60 if u.startswith("m") else 1)
        return total
    # Toute la durée qui suit (jusqu'au point ou à la parenthèse) : chaque « nombre + unité » est
    # additionné (56m23s, 1 hour 30 minutes…).
    for motif in (r"resets? in ([^.;)\n]{1,60})", r"remise à zéro dans ([^.;)\n]{1,60})",
                  r"try again in ([^.;)\n]{1,60})", r"réessa\w* dans ([^.;)\n]{1,60})"):
        m = re.search(motif, texte, re.I)
        if m and duree(m.group(1)):
            return time.time() + duree(m.group(1))
    m = re.search(r"try again (?:at|after) (\d{1,2}):(\d{2})\s*([AP]M)?", texte, re.I)
    if m:
        h, mn = int(m.group(1)) % 12 if m.group(3) else int(m.group(1)), int(m.group(2))
        if m.group(3) and m.group(3).upper() == "PM":
            h += 12
        maintenant = time.localtime()
        cible = time.mktime((maintenant.tm_year, maintenant.tm_mon, maintenant.tm_mday, h, mn, 0, 0, 0, -1))
        return cible if cible > time.time() else cible + 86400
    m = re.search(r'"?resets_at"?\s*[:=]\s*(\d{10})', texte)
    return float(m.group(1)) if m else None


def noter_quota_images(auteur, message=None):
    """Garde la dernière erreur de quota d'images (message d'origine, heure, remise à zéro), ou
    l'heure de la dernière image réussie si `message` est None."""
    maintenant = time.time()
    date_remise = remise_a_zero(message) if message else None

    def modifier(etat):
        e = etat.get(auteur) if isinstance(etat.get(auteur), dict) else {}
        if message:
            e.update(message=message.strip()[:500], heure=maintenant, remise=date_remise)
        else:
            e["dernier_succes"] = maintenant
        etat[auteur] = e
    mettre_a_jour_json(ETAT_QUOTAS_IMAGES, modifier)
    return date_remise


def diagnostic_images(auteur, texte):
    """Aucune image n'est sortie : dit pourquoi, en citant le message d'origine tel quel."""
    brut = (texte or "").strip() or t("img.aucun_message")
    if MOTIF_QUOTA.search(brut):
        date_remise = noter_quota_images(auteur, brut)
        quand = remise(date_remise) if date_remise else t("img.remise_inconnue")
        return t("img.quota_epuise", nom=nom(auteur), quand=quand, message=brut)
    if MOTIF_FILTRE.search(brut):
        return t("img.filtre", nom=nom(auteur), message=brut)
    return t("img.aucun_fichier", nom=nom(auteur), message=brut)


def ligne_images(auteur):
    """Antigravity et Codex ne publient pas de compteur d'images : on montre la
    dernière erreur de quota d'images reçue (avec sa remise à zéro) et la dernière image réussie."""
    e = lire_json(ETAT_QUOTAS_IMAGES).get(auteur)
    e = e if isinstance(e, dict) else {}
    succes = e.get("dernier_succes")
    morceaux = [t("img.q_pas_de_compteur")]
    if not e.get("heure"):
        morceaux.append(t("img.q_aucune_erreur"))
        if succes:
            morceaux.append(t("img.q_derniere_image", date=date_courte(succes)))
        return "  " + t("img.q_titre") + " " + " · ".join(morceaux)
    date_remise = e.get("remise")
    etat_remise = t("img.remise_inconnue") if date_remise is None else remise(date_remise)
    message = " ".join(str(e.get("message", "")).split())
    morceaux.append(t("img.q_derniere_erreur", date=date_courte(e["heure"]), remise=etat_remise,
                      message=message if len(message) <= 200 else message[:197] + "…"))
    if succes and succes > e["heure"]:
        morceaux.append(t("img.q_reussie_depuis", date=date_courte(succes)))
    return "  " + t("img.q_titre") + " " + " · ".join(morceaux)


def resume_ranges(ranges, variantes):
    entete = t("mcp.images_rangees")
    if len(ranges) < variantes:
        entete += " " + t("img.manque", demandees=variantes, obtenues=len(ranges))
    return entete + "\n" + "\n".join("- " + c for c in ranges)


# ---------------------------------------------------------------------------
# Gemini (Antigravity)

def ranger_images_antigravity(destination, nom_fichier, variantes):
    def apres(reponse):
        lignes = reponse.splitlines()
        sources = [l[len("[[image]] "):].strip() for l in lignes if l.startswith("[[image]] ")]
        texte = "\n".join(l for l in lignes if not l.startswith("[[image]] ")).strip()
        # Gemini fait parfois des brouillons avant la version finale : on garde les plus récentes.
        datees = []
        for c in sources:
            try:
                datees.append((os.path.getmtime(c), c))
            except OSError:
                continue
        sources = [c for _, c in sorted(datees)][-variantes:]
        # Ses liens pointent vers son dossier caché : on garde le texte, pas le lien.
        texte = re.sub(r"\[([^\]]+)\]\(file://[^)]*\)", r"\1", texte)
        if not sources:
            return diagnostic_images("antigravity", texte), [], True
        ranges, apercus = copier_images(sources, destination, nom_fichier)
        noter_quota_images("antigravity")
        resume = resume_ranges(ranges, variantes)
        return resume + ("\n\n" + t("mcp.commentaire", nom=nom("antigravity"), texte=texte) if texte else ""), apercus, False
    return apres


# ---------------------------------------------------------------------------
# ChatGPT (Codex)

def session_codex(marque, depuis):
    """La session Codex de la tâche : l'historique (~/.codex/sessions/AAAA/MM/JJ/rollout-….jsonl) écrit
    depuis `depuis` dont la consigne contient la référence unique `marque`.
    Renvoie (identifiant de session, chemin de l'historique) ou (None, None)."""
    jours = set()
    instant = depuis - 3600
    while instant <= time.time() + 3600:
        for conversion in (time.localtime, time.gmtime):
            jours.add(time.strftime("%Y/%m/%d", conversion(instant)))
        instant += 3600
    candidats = []
    for jour in jours:
        dossier = os.path.join(SESSIONS_CODEX, jour)
        try:
            noms_fichiers = os.listdir(dossier)
        except OSError:
            continue
        for n in noms_fichiers:
            chemin = os.path.join(dossier, n)
            try:
                date = os.path.getmtime(chemin)
            except OSError:
                continue
            if n.startswith("rollout-") and n.endswith(".jsonl") and date >= depuis - 5:
                candidats.append((date, chemin))
    for _, chemin in sorted(candidats, reverse=True):
        try:
            with open(chemin, encoding="utf-8", errors="replace") as f:
                for i, ligne in enumerate(f):
                    if marque in ligne:
                        m = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$", chemin)
                        return (m.group(1) if m else None), chemin
                    if i > 80:            # la consigne est au tout début de l'historique
                        break
        except OSError:
            continue
    return None, None


def texte_echec(valeur):
    if isinstance(valeur, dict):
        return valeur.get("message") or valeur.get("error") or json.dumps(valeur, ensure_ascii=False)
    return str(valeur)


def images_de_session(chemin):
    """Lit l'historique Codex de la tâche : chemins des images enregistrées par l'outil d'image
    (« savedPath ») et messages d'échec (outil d'image, erreurs de Codex), mot pour mot."""
    enregistrees, echecs, appels_image = [], [], set()
    try:
        with open(chemin, encoding="utf-8", errors="replace") as f:
            for brut in f:
                if not any(c in brut for c in ("image_gen", '"error"', "custom_tool_call_output")):
                    continue
                try:
                    p = json.loads(brut).get("payload") or {}
                except (ValueError, AttributeError):
                    continue
                if not isinstance(p, dict):
                    continue
                genre = p.get("type")
                item = p.get("item") if isinstance(p.get("item"), dict) else {}
                if genre == "item_completed" and item.get("kind") == "image_gen.generation":
                    if item.get("savedPath") and item.get("status") == "completed":
                        enregistrees.append(item["savedPath"])
                    if item.get("failure") or item.get("status") not in ("completed", None):
                        echecs.append("image_gen (%s) : %s" % (item.get("status"),
                                                              texte_echec(item.get("failure") or "failed")))
                elif genre == "error" and p.get("message"):
                    echecs.append("Codex : %s" % p["message"])
                elif genre == "custom_tool_call" and "image_gen" in str(p.get("input", "")):
                    appels_image.add(p.get("call_id"))
                elif genre == "custom_tool_call_output" and p.get("call_id") in appels_image:
                    for morceau in p.get("output") or []:
                        texte = morceau.get("text", "") if isinstance(morceau, dict) else ""
                        if re.search(r"error|erreur|limit|quota|polic|safety|refus", texte, re.I):
                            echecs.append("image_gen : %s" % texte.strip()[:4000])
    except OSError as erreur:
        echecs.append(t("img.historique_illisible", erreur=erreur))
    return enregistrees, echecs


def images_recentes(dossier, depuis):
    resultat = []
    for racine, _, noms_fichiers in os.walk(dossier):
        for n in noms_fichiers:
            chemin = os.path.join(racine, n)
            try:
                if n.lower().endswith(EXTENSIONS_IMAGES) and os.path.getmtime(chemin) >= depuis - 2:
                    resultat.append(chemin)
            except OSError:
                continue
    return resultat


def ranger_images_codex(destination, nom_fichier, variantes, depuis, marque):
    def apres(reponse):
        session, historique = session_codex(marque, depuis)
        enregistrees, echecs = images_de_session(historique) if historique else ([], [])
        # Fichiers réellement présents : ceux que l'outil dit avoir enregistrés, plus ceux du dossier de
        # la session (on ne se fie pas au chemin annoncé dans la réponse).
        candidats = {c for c in enregistrees if os.path.isfile(c)}
        if session:
            candidats |= set(images_recentes(os.path.join(IMAGES_CODEX, session), depuis))
        datees = []
        for c in candidats:
            try:
                datees.append((os.path.getmtime(c), c))
            except OSError:
                continue
        sources = [c for _, c in sorted(datees)][-variantes:]
        texte = reponse.strip()
        if not sources:
            details = "\n".join(echecs)
            if not historique:
                details = (t("img.session_introuvable", marque=marque) + "\n" + details).strip()
            return diagnostic_images("codex", (details + "\n\n" + texte).strip()), [], True
        ranges, apercus = copier_images(sources, destination, nom_fichier)
        noter_quota_images("codex")
        resume = resume_ranges(ranges, variantes)
        if echecs:
            resume += "\n\n" + t("img.messages_outil") + "\n" + "\n".join(echecs)
        return resume + ("\n\n" + t("mcp.commentaire", nom=nom("codex"), texte=texte) if texte else ""), apercus, False
    return apres


# ---------------------------------------------------------------------------
# L'outil

def faire_une_image(arguments, progression, manque_programme):
    entree_outil = time.time()
    description = arguments.get("description")
    description = description.strip() if isinstance(description, str) else ""
    if not description:
        return t("mcp.description_vide"), True
    possibles = auteurs_images()
    demande = arguments.get("auteur")
    demande = demande.strip() if isinstance(demande, str) else ""
    auteur = possibles[0] if possibles and not demande else next(
        (c for c in possibles if demande.lower() in (MEMBRES[c]["slug"], c, MEMBRES[c]["nom"].lower())), None)
    if auteur is None:
        return t("img.auteur_inconnu", auteur=demande,
                 auteurs=", ".join("« %s »" % MEMBRES[c]["slug"] for c in possibles) or "—"), True
    destination, refus = dossier_autorise(arguments.get("destination")
                                          if isinstance(arguments.get("destination"), str) else "")
    if refus:
        return t("mcp.dest_refusee", raison=refus), True
    nom_fichier = nom_de_fichier(arguments.get("nom") if isinstance(arguments.get("nom"), str) else "",
                                 MEMBRES[auteur]["slug"])
    variantes = arguments.get("variantes")
    # L'app annonce parfois ce champ comme « number » : 2.0 doit valoir 2.
    if isinstance(variantes, float) and variantes.is_integer():
        variantes = int(variantes)
    variantes = variantes if isinstance(variantes, int) and not isinstance(variantes, bool) and 1 <= variantes <= 4 else 1
    os.makedirs(ATELIER, exist_ok=True)
    manque = manque_programme(auteur)
    if manque:
        return manque, True
    if auteur == "codex":
        marque = "img-%s" % uuid.uuid4().hex
        depuis = time.time()
        consigne = (t("img.consigne_codex_une", description=description, marque=marque) if variantes == 1
                    else t("img.consigne_codex_plusieurs", n=variantes, description=description, marque=marque))
        tache = Tache("codex", consigne, ATELIER,
                      apres=ranger_images_codex(destination, nom_fichier, variantes, depuis, marque),
                      apres_toujours=True)
    else:
        consigne = (t("mcp.consigne_image_une", description=description) if variantes == 1
                    else t("mcp.consigne_image_plusieurs", n=variantes, description=description))
        tache = Tache("antigravity", consigne, ATELIER,
                      apres=ranger_images_antigravity(destination, nom_fichier, variantes), apres_toujours=True)
    enregistrer(tache)
    journal(t("mcp.j_image", tache=tache.id, destination=destination))
    return attendre_ou_numero(tache, progression, entree_outil)
