# Sauvegarde USB

Copie automatiquement les sauvegardes de Home Assistant sur un **disque dur, un SSD ou une clé USB** branché sur la machine Home Assistant.

Home Assistant OS ne sait pas (encore) utiliser un disque USB comme emplacement de sauvegarde. Cet add-on comble ce manque **sans modifier le système** : il monte le disque uniquement dans son propre conteneur, le temps de la copie, puis le démonte.

## Ce que fait l'add-on

1. Toutes les X minutes, il regarde les sauvegardes présentes dans Home Assistant.
2. Il copie sur le disque celles qui n'y sont pas encore (seulement les plus récentes, selon « Nombre de copies à garder »). Une sauvegarde encore en cours d'écriture attend le passage suivant.
3. Il **vérifie** chaque copie (taille, empreinte SHA-256, lecture de l'archive). Une copie incomplète n'est jamais gardée.
4. Il garde les **N copies les plus récentes** sur le disque et supprime les plus anciennes. Il garde ses copies même quand Home Assistant a supprimé les originaux de son côté.
5. Il démonte le disque et met à jour le capteur `sensor.sauvegarde_usb`.
6. Il te prévient selon tes réglages.

Les fichiers sont nommés lisiblement : `2026-11-18_0508_Sauvegarde_automatique_ab12cd34.tar`.

## Sécurité de tes données

- L'add-on **ne formate jamais** le disque.
- Il ne supprime **que ses propres copies**, dans son dossier, reconnues à leur nom. Tes autres fichiers ne sont jamais touchés.
- Il ne supprime une ancienne copie pour faire de la place **que si ça suffit vraiment**. Sinon, il ne touche à rien et te signale l'erreur.
- Le dossier des sauvegardes de Home Assistant est monté **en lecture seule** : l'add-on ne peut pas abîmer les originaux.

## Préparer le disque

1. Sur un PC, formate le disque en **exFAT** (conseillé : lisible sous Windows, macOS et Linux). **ext4** et **NTFS** fonctionnent aussi. **Évite FAT32** : il refuse les fichiers de plus de 4 Go.
2. Donne-lui un **nom de volume** court (11 caractères max. pour être sûr), par exemple `SAUVEGARDE`. Sous Windows : clic droit sur le disque → Propriétés → nom.
3. Branche-le sur la machine Home Assistant.

**Taille du disque** : prévois au moins « Nombre de copies à garder » × la taille d'une sauvegarde, plus une marge. Tu trouves la taille d'une sauvegarde dans Paramètres → Système → Sauvegardes.

## Configuration

| Option | Rôle | Par défaut |
|---|---|---|
| Nom du volume du disque | Nom exact du disque (majuscules comprises) | `SAUVEGARDE_HA` |
| Dossier sur le disque | Dossier des copies | `home_assistant_backups` |
| Nombre de copies à garder | Copies conservées sur le disque | `5` |
| Contrôle toutes les (minutes) | Fréquence de vérification | `10` |
| Vérification complète | Contrôle SHA-256 de chaque copie | oui |
| Espace libre minimum (Go) | Marge à laisser sur le disque | `1` |
| Sauvegardes complètes seulement | Ignore les sauvegardes partielles (mises à jour de modules) | oui |
| Quand prévenir | `none`, `errors` ou `always` | `errors` |
| Comment prévenir | `persistent`, `notify` ou `discord` | `persistent` |
| Service de notification | ex. `notify.mobile_app_mon_telephone` | — |
| Webhook Discord | URL du webhook | — |

Les erreurs ne sont signalées **qu'une fois** tant que le même problème persiste, et l'add-on te prévient quand c'est réglé.

## Commandes

Tu peux piloter l'add-on depuis une automatisation, un script ou un bouton :

```yaml
action: hassio.addon_stdin
data:
  addon: local_sauvegarde_usb
  input: copy   # copie immédiate (ou « test » pour une notification de test)
```

Le nom `local_sauvegarde_usb` vaut pour une installation en add-on local. Si tu l'installes depuis un dépôt GitHub, regarde le nom exact (slug) affiché sur la page de l'add-on.

## Capteur

`sensor.sauvegarde_usb` prend l'état `ok`, `erreur` ou `aucune_sauvegarde`, avec ces attributs : disque, dernière copie, nombre de copies sur le disque, espace libre en Go, heure du dernier contrôle. Il est recréé par l'add-on, donc il disparaît si Home Assistant redémarre pendant que l'add-on est arrêté.

## Important : désactiver le « Mode de protection »

Sur la page de l'add-on, **désactive le « Mode de protection »** puis redémarre l'add-on. Tant qu'il est activé, Home Assistant refuse à l'add-on l'accès au disque USB : la clé est vue mais ne peut pas être lue ni montée (le journal l'indique).

## Droits demandés

Pour monter un disque, l'add-on a besoin d'un **accès complet au matériel** et du droit **SYS_ADMIN**. Home Assistant lui donne donc une note de sécurité plus basse. C'est normal pour ce genre d'outil. Le code est court et lisible dans `run.sh`.

## Conseils

- Garde aussi le **kit d'urgence** (clé de chiffrement) de tes sauvegardes **hors de Home Assistant** : Paramètres → Système → Sauvegardes → ⋮.
- Le disque reste branché à côté de la machine : il te protège d'une panne de disque, mais pas d'un incendie ou d'un vol. Une copie de temps en temps ailleurs reste une bonne idée.

---

## English (short)

Automatically copies Home Assistant backups to a USB drive identified by its **volume label**. The drive is mounted only inside the add-on container during the copy. It keeps the last N copies, verifies each one (size + SHA-256 + archive read), never formats anything, and only deletes its own files. Notifications go to a persistent notification, a `notify.*` service (Companion app) or a Discord webhook. Format the drive as exFAT (recommended), ext4 or NTFS, not FAT32. Use `hassio.addon_stdin` with `copy` or `test`.
