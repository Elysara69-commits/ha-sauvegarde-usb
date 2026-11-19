# Changelog

## 1.0.0
- Première version : copie automatique des sauvegardes vers un disque USB identifié par son nom de volume.
- Rétention (N dernières copies sur le disque, indépendamment de ce que Home Assistant garde en local).
- Vérification taille + SHA-256 + lecture de l'archive.
- Notifications : persistante, service notify (appli Companion) ou Discord ; jamais / erreurs / toujours.
- Capteur `sensor.sauvegarde_usb`.
- Commandes via `hassio.addon_stdin` : `copy` (copie immédiate) et `test` (notification de test).
