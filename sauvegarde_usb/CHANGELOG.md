# Changelog

## 1.1.0
- **Correctif important** : les sauvegardes récentes de Home Assistant (fichiers nommés comme `Automatic_backup_2026.11.2_….tar`) n'étaient pas détectées (« Aucune sauvegarde dans /backup »). L'identifiant, le nom et la date sont désormais lus dans le `backup.json` de chaque archive, quel que soit le nom du fichier.
- Nouvelle option **« Sauvegardes complètes seulement »** (activée par défaut) : les petites sauvegardes partielles créées avant la mise à jour d'un module ne prennent plus la place des vraies sauvegardes.
- Le journal et les noms de fichiers utilisent le fuseau horaire de Home Assistant (au lieu de l'heure UTC).

## 1.0.0
- Première version : copie automatique des sauvegardes vers un disque USB identifié par son nom de volume.
- Rétention (N dernières copies sur le disque, indépendamment de ce que Home Assistant garde en local).
- Vérification taille + SHA-256 + lecture de l'archive.
- Notifications : persistante, service notify (appli Companion) ou Discord ; jamais / erreurs / toujours.
- Capteur `sensor.sauvegarde_usb`.
- Commandes via `hassio.addon_stdin` : `copy` (copie immédiate) et `test` (notification de test).
