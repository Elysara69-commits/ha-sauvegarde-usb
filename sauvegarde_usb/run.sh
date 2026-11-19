#!/usr/bin/with-contenv bash
# with-contenv : charge l'environnement fourni par le Supervisor (SUPERVISOR_TOKEN, TZ…)
# =============================================================================
#  Sauvegarde USB — add-on Home Assistant
#  Copie les sauvegardes de /backup vers un disque USB identifié par son nom
#  de volume (label), avec rétention, vérification et notifications.
#
#  Le disque est monté UNIQUEMENT dans le conteneur de l'add-on, le temps de
#  la copie, puis démonté. L'add-on ne formate jamais rien et ne supprime que
#  les fichiers qu'il a lui-même créés dans son dossier.
# =============================================================================
set -u

VERSION="1.1.2"
OPTIONS_FILE="${OPTIONS_FILE:-/data/options.json}"
BACKUP_DIR="${BACKUP_DIR:-/backup}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/usb_backup}"
STATE_FILE="${STATE_FILE:-/data/state.json}"
SUPERVISOR="${SUPERVISOR_URL:-http://supervisor}"
TOKEN="${SUPERVISOR_TOKEN:-}"
# Mode test : FAKE_DISK_DIR remplace le disque (pas de mount/umount)
FAKE_DISK_DIR="${FAKE_DISK_DIR:-}"
RUN_ONCE="${RUN_ONCE:-0}"

# Nom de fichier produit : AAAA-MM-JJ_HHMM_<nom>_<slug>.tar
OWN_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}_.*_[A-Za-z0-9]+\.tar$'
STABLE_SECONDS=120       # une sauvegarde modifiée il y a moins de 2 min est en cours
FAT32_MAX=4294967295     # taille max d'un fichier sur FAT32

# --------------------------------------------------------------------------- #
# Journal
# --------------------------------------------------------------------------- #
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
info() { echo "[$(ts)] INFO  $*"; }
warn() { echo "[$(ts)] WARN  $*"; }
err()  { echo "[$(ts)] ERREUR $*"; }

# --------------------------------------------------------------------------- #
# Options
# --------------------------------------------------------------------------- #
# NB : pas de « // empty » ici, sinon jq transforme la valeur false en vide (option ignorée)
opt() { jq -r --arg k "$1" 'if has($k) and .[$k] != null then .[$k] else empty end' "$OPTIONS_FILE" 2>/dev/null; }

load_options() {
  DEVICE_LABEL="$(opt device_label)"
  FOLDER="$(opt folder)"; FOLDER="${FOLDER:-home_assistant_backups}"
  KEEP_LAST="$(opt keep_last)"; KEEP_LAST="${KEEP_LAST:-5}"
  INTERVAL_MIN="$(opt check_interval_minutes)"; INTERVAL_MIN="${INTERVAL_MIN:-10}"
  VERIFY="$(opt verify_checksum)"; VERIFY="${VERIFY:-true}"
  MIN_FREE_GB="$(opt min_free_gb)"; MIN_FREE_GB="${MIN_FREE_GB:-1}"
  NOTIF_MODE="$(opt notification_mode)"; NOTIF_MODE="${NOTIF_MODE:-errors}"
  NOTIF_CHANNEL="$(opt notification_channel)"; NOTIF_CHANNEL="${NOTIF_CHANNEL:-persistent}"
  NOTIFY_SERVICE="$(opt notify_service)"
  DISCORD_WEBHOOK="$(opt discord_webhook)"
  ONLY_FULL="$(opt only_full_backups)"; [[ "$ONLY_FULL" == "false" ]] || ONLY_FULL="true"

  # garde-fous (le schéma de l'add-on valide déjà, mais on reste prudent)
  [[ "$KEEP_LAST" =~ ^[0-9]+$ ]] && (( KEEP_LAST >= 1 )) || KEEP_LAST=5
  [[ "$INTERVAL_MIN" =~ ^[0-9]+$ ]] && (( INTERVAL_MIN >= 1 )) || INTERVAL_MIN=10
  [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || MIN_FREE_GB=1
  [[ "$FOLDER" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$FOLDER" != "." && "$FOLDER" != ".." ]] || FOLDER="home_assistant_backups"
}

# --------------------------------------------------------------------------- #
# API Home Assistant / Supervisor
# --------------------------------------------------------------------------- #
api() { # api METHOD PATH [JSON]
  [[ -z "$TOKEN" ]] && return 1
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS -m 20 -X "$method" -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" -d "$data" "${SUPERVISOR}${path}"
  else
    curl -sS -m 20 -X "$method" -H "Authorization: Bearer ${TOKEN}" "${SUPERVISOR}${path}"
  fi
}

# Envoie une notification selon la configuration.
# notify LEVEL(info|success|error) TITRE MESSAGE
notify() {
  local level="$1" title="$2" message="$3"
  case "$NOTIF_MODE" in
    none) return 0 ;;
    errors) [[ "$level" == "error" ]] || return 0 ;;
  esac
  local color=3066993
  [[ "$level" == "error" ]] && color=15158332
  [[ "$level" == "info" ]] && color=3447003

  case "$NOTIF_CHANNEL" in
    persistent)
      api POST /core/api/services/persistent_notification/create \
        "$(jq -nc --arg t "$title" --arg m "$message" '{title:$t, message:$m, notification_id:"sauvegarde_usb"}')" >/dev/null \
        || warn "Notification persistante impossible"
      ;;
    notify)
      local svc="${NOTIFY_SERVICE#notify.}"
      if [[ -z "$svc" || ! "$svc" =~ ^[a-z0-9_]+$ ]]; then
        warn "notify_service invalide ou vide (ex. notify.mobile_app_mon_telephone)"
        return 0
      fi
      api POST "/core/api/services/notify/${svc}" \
        "$(jq -nc --arg t "$title" --arg m "$message" '{title:$t, message:$m}')" >/dev/null \
        || warn "Notification ${NOTIFY_SERVICE} impossible"
      ;;
    discord)
      if [[ ! "$DISCORD_WEBHOOK" =~ ^https://(discord\.com|discordapp\.com|ptb\.discord\.com|canary\.discord\.com)/api/webhooks/ ]]; then
        warn "discord_webhook invalide ou vide"
        return 0
      fi
      curl -sS -m 20 -H "Content-Type: application/json" \
        -d "$(jq -nc --arg t "$title" --arg m "$message" --argjson c "$color" \
              '{username:"Sauvegarde USB", embeds:[{title:$t, description:$m, color:$c}]}')" \
        "$DISCORD_WEBHOOK" >/dev/null || warn "Notification Discord impossible"
      ;;
  esac
}

# Capteur dans Home Assistant : sensor.sauvegarde_usb
publish_sensor() { # publish_sensor ETAT JSON_ATTRIBUTS
  api POST /core/api/states/sensor.sauvegarde_usb \
    "$(jq -nc --arg s "$1" --argjson a "$2" \
       '{state:$s, attributes:($a + {friendly_name:"Sauvegarde USB", icon:"mdi:usb-flash-drive"})}')" >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------- #
# État persistant (anti-spam des erreurs)
# --------------------------------------------------------------------------- #
state_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null; }
state_set() {
  local tmp; tmp="$(mktemp)"
  if [[ -s "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    jq --arg k "$1" --arg v "$2" '.[$k]=$v' "$STATE_FILE" >"$tmp"
  else
    jq -n --arg k "$1" --arg v "$2" '{($k):$v}' >"$tmp"
  fi
  mv "$tmp" "$STATE_FILE"
}

# Erreur : notifiée une seule fois tant que la même erreur se répète
fail() { # fail CLE MESSAGE
  local key="$1" msg="$2"
  err "$msg"
  if [[ "$(state_get last_error)" != "$key" ]]; then
    notify error "❌ Sauvegarde USB" "$msg"
    state_set last_error "$key"
  fi
  publish_sensor "erreur" "$(jq -nc --arg m "$msg" --arg d "$DEVICE_LABEL" '{dernier_message:$m, disque:$d}')"
}

clear_error() {
  if [[ -n "$(state_get last_error)" ]]; then
    state_set last_error ""
    [[ "$NOTIF_MODE" != "none" ]] && info "Problème résolu"
  fi
}

# --------------------------------------------------------------------------- #
# Disque
# --------------------------------------------------------------------------- #
DISK_ROOT=""
MOUNTED_BY_US=0
FSTYPE=""

mount_disk() {
  if [[ -n "$FAKE_DISK_DIR" ]]; then
    DISK_ROOT="$FAKE_DISK_DIR"; FSTYPE="${FAKE_FSTYPE:-exfat}"
    return 0
  fi
  if [[ -z "$DEVICE_LABEL" ]]; then
    fail no_label "Aucun nom de volume configuré (option device_label)."
    return 1
  fi
  local dev
  dev="$(blkid -L "$DEVICE_LABEL" 2>/dev/null || true)"
  if [[ -z "$dev" ]]; then
    fail no_disk "Disque « ${DEVICE_LABEL} » introuvable. Est-il bien branché ? (nom de volume exact, majuscules comprises)"
    # Aide au diagnostic : ce que le système voit comme disques USB
    local usb
    usb="$(lsblk -rno NAME,SIZE,FSTYPE,LABEL,TRAN 2>/dev/null | awk '$NF=="usb" || /^sd[b-z][0-9]/' | head -n 10)"
    if [[ -n "$usb" ]]; then
      info "Disques USB vus (nom taille système label) :"
      while IFS= read -r l; do info "   ${l}"; done <<<"$usb"
    else
      info "Aucun disque USB détecté."
    fi
    return 1
  fi
  # Le disque doit être lisible : sinon c'est le « Mode de protection » qui bloque l'accès
  if ! dd if="$dev" of=/dev/null bs=4096 count=1 2>/dev/null; then
    fail no_access "Disque « ${DEVICE_LABEL} » trouvé (${dev}) mais illisible : désactive le « Mode de protection » de l'add-on (page de l'add-on), puis redémarre-le."
    return 1
  fi
  # -p : lecture directe du disque (sans cache) ; lsblk en secours
  FSTYPE="$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)"
  [[ -z "$FSTYPE" ]] && FSTYPE="$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1 | tr -d ' ')"
  local mtype="$FSTYPE"
  case "$FSTYPE" in
    ext2|ext3|ext4|exfat|vfat|btrfs|xfs) ;;
    ntfs) mtype="ntfs3" ;;
    *) fail bad_fs "Système de fichiers « ${FSTYPE:-inconnu} » non pris en charge sur ${dev}. Utilise exFAT (conseillé) ou ext4."; return 1 ;;
  esac
  mkdir -p "$MOUNT_POINT"
  if mountpoint -q "$MOUNT_POINT"; then
    DISK_ROOT="$MOUNT_POINT"; MOUNTED_BY_US=0
    return 0
  fi
  if ! mount -t "$mtype" -o rw,noatime "$dev" "$MOUNT_POINT" 2>/tmp/mount.err; then
    fail mount_fail "Montage de ${dev} (${FSTYPE}) impossible : $(tr '\n' ' ' </tmp/mount.err)"
    return 1
  fi
  DISK_ROOT="$MOUNT_POINT"; MOUNTED_BY_US=1
  info "Disque ${DEVICE_LABEL} (${dev}, ${FSTYPE}) monté"
  return 0
}

umount_disk() {
  [[ -n "$FAKE_DISK_DIR" ]] && return 0
  if (( MOUNTED_BY_US )) && mountpoint -q "$MOUNT_POINT"; then
    sync
    umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || warn "Démontage impossible"
    MOUNTED_BY_US=0
    info "Disque démonté"
  fi
}

free_bytes() { df -PB1 "$1" | awk 'NR==2 {print $4}'; }

# --------------------------------------------------------------------------- #
# Sauvegardes
# --------------------------------------------------------------------------- #
# Liste "epoch|slug|nom|chemin" des sauvegardes présentes dans /backup, plus récentes d'abord.
# Les fichiers peuvent avoir n'importe quel nom (depuis 2025 : « Automatic_backup_2026.11.2_….tar ») :
# l'identifiant, le nom et la date sont lus dans le backup.json contenu dans l'archive.
read_meta() { # read_meta FICHIER -> JSON du backup.json (vide si illisible)
  tar -xOf "$1" ./backup.json 2>/dev/null || tar -xOf "$1" backup.json 2>/dev/null || true
}

list_backups() {
  local f slug epoch name date meta type ha
  for f in "$BACKUP_DIR"/*.tar; do
    [[ -f "$f" ]] || continue
    meta="$(read_meta "$f")"
    slug=""; name=""; date=""; type=""; ha=""
    # pas de backup.json lisible : ce n'est pas une sauvegarde Home Assistant (ou elle est en cours d'écriture)
    if [[ -z "$meta" ]] || ! jq -e . >/dev/null 2>&1 <<<"$meta"; then
      continue
    fi
    if true; then
      slug="$(jq -r '.slug // empty' <<<"$meta")"
      name="$(jq -r '.name // empty' <<<"$meta")"
      date="$(jq -r '.date // empty' <<<"$meta")"
      type="$(jq -r '.type // empty' <<<"$meta")"
      ha="$(jq -r 'if .homeassistant then "oui" else "" end' <<<"$meta")"
    fi
    # Sauvegardes partielles (ex. créées avant la mise à jour d'un module) : ignorées si demandé
    if [[ "$ONLY_FULL" == "true" && "$type" != "full" && -z "$ha" ]]; then
      continue
    fi
    # identifiant de secours : nom du fichier réduit aux lettres et chiffres
    [[ "$slug" =~ ^[A-Za-z0-9]+$ ]] || slug="$(basename "$f" .tar | tr -cd 'A-Za-z0-9' | tail -c 24)"
    [[ -n "$slug" ]] || continue
    epoch=""
    [[ -n "$date" ]] && epoch="$(date -d "$date" +%s 2>/dev/null || true)"
    [[ -z "$epoch" ]] && epoch="$(stat -c %Y "$f")"
    name="${name//|/ }"; [[ -z "$name" ]] && name="sauvegarde"
    printf '%s|%s|%s|%s\n' "$epoch" "$slug" "$name" "$f"
  done | sort -t'|' -k1,1nr
}

safe_name() { # nom lisible et sûr pour un nom de fichier
  local s
  # translittération caractère par caractère (iconv //TRANSLIT ne fonctionne pas sous Alpine/musl,
  # et les classes [éè] de sed sont fausses hors locale UTF-8)
  s="$(printf '%s' "$1" | sed \
    -e 's/à/a/g; s/â/a/g; s/ä/a/g; s/á/a/g; s/ã/a/g; s/å/a/g; s/À/A/g; s/Â/A/g' \
    -e 's/Ä/A/g; s/Á/A/g; s/Ã/A/g; s/Å/A/g; s/é/e/g; s/è/e/g; s/ê/e/g; s/ë/e/g' \
    -e 's/É/E/g; s/È/E/g; s/Ê/E/g; s/Ë/E/g; s/î/i/g; s/ï/i/g; s/í/i/g; s/ì/i/g' \
    -e 's/Î/I/g; s/Ï/I/g; s/Í/I/g; s/Ì/I/g; s/ô/o/g; s/ö/o/g; s/ó/o/g; s/ò/o/g' \
    -e 's/õ/o/g; s/Ô/O/g; s/Ö/O/g; s/Ó/O/g; s/Ò/O/g; s/Õ/O/g; s/û/u/g; s/ü/u/g' \
    -e 's/ú/u/g; s/ù/u/g; s/Û/U/g; s/Ü/U/g; s/Ú/U/g; s/Ù/U/g; s/ç/c/g; s/Ç/C/g' \
    -e 's/ñ/n/g; s/Ñ/N/g; s/ÿ/y/g; s/œ/oe/g; s/Œ/OE/g; s/æ/ae/g; s/Æ/AE/g')"
  s="$(printf '%s' "$s" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//; s/_*$//' | cut -c1-60)"
  printf '%s' "${s:-sauvegarde}"
}

target_name() { # target_name EPOCH SLUG NOM
  printf '%s_%s_%s.tar' "$(date -d "@$1" '+%Y-%m-%d_%H%M')" "$(safe_name "$3")" "$2"
}

own_files() { # fichiers créés par l'add-on dans le dossier cible
  local dir="$1" f
  for f in "$dir"/*.tar; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" =~ $OWN_PATTERN ]] && echo "$f"
  done
}

# Plus ancienne de nos copies qu'on peut sacrifier pour faire de la place :
# jamais une copie d'une sauvegarde de la liste « à garder » (KEEP_SLUGS).
oldest_prunable() {
  local dir="$1" f slug
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    slug="$(basename "$f" .tar)"; slug="${slug##*_}"
    [[ "$KEEP_SLUGS" == *" ${slug} "* ]] && continue
    echo "$f"; return 0
  done < <(own_files "$dir" | sort)
  return 0
}

prunable_bytes() { # taille totale de nos copies sacrifiables
  local dir="$1" f slug total=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    slug="$(basename "$f" .tar)"; slug="${slug##*_}"
    [[ "$KEEP_SLUGS" == *" ${slug} "* ]] && continue
    total=$(( total + $(stat -c %s "$f") ))
  done < <(own_files "$dir")
  echo "$total"
}

copy_one() { # copy_one SOURCE DESTINATION
  local src="$1" dst="$2" part="${2}.part"
  rm -f "$part"
  if ! cp -f "$src" "$part"; then
    rm -f "$part"; return 1
  fi
  sync
  local s1 s2
  s1="$(stat -c %s "$src")"; s2="$(stat -c %s "$part")"
  if [[ "$s1" != "$s2" ]]; then
    err "Taille différente après copie ($s1 ≠ $s2)"; rm -f "$part"; return 1
  fi
  if [[ "$VERIFY" == "true" ]]; then
    local h1 h2
    h1="$(sha256sum "$src" | cut -d' ' -f1)"; h2="$(sha256sum "$part" | cut -d' ' -f1)"
    if [[ "$h1" != "$h2" ]]; then
      err "Somme de contrôle différente après copie"; rm -f "$part"; return 1
    fi
  fi
  if ! tar -tf "$part" >/dev/null 2>&1; then
    err "Archive illisible après copie"; rm -f "$part"; return 1
  fi
  mv -f "$part" "$dst"
}

# --------------------------------------------------------------------------- #
# Un passage complet
# --------------------------------------------------------------------------- #
run_cycle() {
  local now; now="$(date +%s)"
  mapfile -t ALL < <(list_backups)
  if (( ${#ALL[@]} == 0 )); then
    info "Aucune sauvegarde dans ${BACKUP_DIR}"
    publish_sensor "aucune_sauvegarde" '{}'
    return 0
  fi

  # Les N plus récentes, terminées (stables depuis 2 min)
  local keep=() line epoch slug name f
  for line in "${ALL[@]}"; do
    IFS='|' read -r epoch slug name f <<<"$line"
    if (( now - $(stat -c %Y "$f") < STABLE_SECONDS )); then
      info "Sauvegarde ${slug} encore en cours d'écriture, elle sera copiée au prochain passage"
      continue
    fi
    keep+=("$line")
    (( ${#keep[@]} >= KEEP_LAST )) && break
  done
  (( ${#keep[@]} == 0 )) && return 0
  KEEP_SLUGS=" "
  for line in "${keep[@]}"; do IFS='|' read -r epoch slug name f <<<"$line"; KEEP_SLUGS+="${slug} "; done

  mount_disk || return 1
  local dir="${DISK_ROOT}/${FOLDER}"
  if ! mkdir -p "$dir" 2>/dev/null; then
    fail write_fail "Impossible de créer le dossier ${FOLDER} sur le disque (lecture seule ?)."
    umount_disk; return 1
  fi

  # Que manque-t-il sur le disque ?
  local missing=() existing
  for line in "${keep[@]}"; do
    IFS='|' read -r epoch slug name f <<<"$line"
    existing="$(own_files "$dir" | grep -E "_${slug}\.tar$" | head -n1 || true)"
    [[ -z "$existing" ]] && missing+=("$line")
  done

  rm -f "$dir"/*.part 2>/dev/null || true
  local deleted=0
  local copied=0 failed=0 copied_names=()
  for line in "${missing[@]}"; do
    IFS='|' read -r epoch slug name src <<<"$line"
    local dst size free need
    dst="${dir}/$(target_name "$epoch" "$slug" "$name")"
    size="$(stat -c %s "$src")"
    if [[ "$FSTYPE" == "vfat" ]] && (( size > FAT32_MAX )); then
      fail fat32 "La sauvegarde « ${name} » fait plus de 4 Go : impossible sur un disque FAT32. Reformate-le en exFAT."
      failed=$((failed+1)); continue
    fi
    need=$(( size + MIN_FREE_GB * 1024 * 1024 * 1024 ))
    free="$(free_bytes "$dir")"
    # Place insuffisante : on libère en supprimant nos plus anciennes copies (sauf les récentes à garder),
    # mais seulement si ça suffit vraiment — sinon on ne détruit rien pour rien.
    if (( free < need )) && (( free + $(prunable_bytes "$dir") >= need )); then
    while (( free < need )); do
      local victim
      victim="$(oldest_prunable "$dir")"
      [[ -z "$victim" ]] && break
      rm -f "$victim" && deleted=$((deleted+1)) && info "Place libérée : $(basename "$victim") supprimée"
      free="$(free_bytes "$dir")"
    done
    fi
    if (( free < need )); then
      fail no_space "Place insuffisante sur ${DEVICE_LABEL} pour « ${name} » ($(( size / 1048576 )) Mo, libre $(( free / 1048576 )) Mo). Réduis keep_last ou utilise un disque plus grand."
      failed=$((failed+1)); continue
    fi
    info "Copie de « ${name} » ($(( size / 1048576 )) Mo) → $(basename "$dst")"
    if copy_one "$src" "$dst"; then
      copied=$((copied+1)); copied_names+=("$name")
      info "Copie vérifiée ✔"
    else
      fail copy_fail "La copie de « ${name} » a échoué (voir le journal de l'add-on)."
      failed=$((failed+1))
    fi
  done

  # Rétention : on garde les KEEP_LAST copies les plus récentes PRÉSENTES SUR LE DISQUE
  # (indépendamment de ce que Home Assistant garde encore localement)
  local n=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    n=$((n+1))
    if (( n > KEEP_LAST )); then
      rm -f "$f" && deleted=$((deleted+1)) && info "Ancienne copie supprimée : $(basename "$f")"
    fi
  done < <(own_files "$dir" | sort -r)

  # Bilan
  local count free_gb last_file
  count="$(own_files "$dir" | wc -l | tr -d ' ')"
  free_gb="$(awk -v b="$(free_bytes "$dir")" 'BEGIN{printf "%.1f", b/1073741824}')"
  last_file="$(own_files "$dir" | xargs -r -n1 basename | sort -r | head -n1)"
  umount_disk

  if (( failed == 0 )); then
    clear_error
    publish_sensor "ok" "$(jq -nc --arg d "$DEVICE_LABEL" --arg l "$last_file" --arg f "$free_gb" \
      --argjson c "$count" --arg t "$(date -Iseconds)" \
      '{disque:$d, derniere_copie:$l, copies_sur_disque:$c, espace_libre_go:($f|tonumber), dernier_controle:$t}')"
    if (( copied > 0 )); then
      local list; list="$(printf '• %s\n' "${copied_names[@]}")"
      notify success "✅ Sauvegarde USB" "$(printf '%s copiée(s) sur %s :\n%s\n%s copie(s) sur le disque, %s Go libres.' \
        "$copied" "$DEVICE_LABEL" "$list" "$count" "$free_gb")"
    fi
  fi
  (( copied > 0 || deleted > 0 )) && info "Bilan : ${copied} copiée(s), ${deleted} ancienne(s) supprimée(s), ${count} sur le disque, ${free_gb} Go libres"
  return 0
}

# --------------------------------------------------------------------------- #
# Programme principal
# --------------------------------------------------------------------------- #
cleanup() { umount_disk; info "Arrêt de l'add-on"; exit 0; }
trap cleanup SIGTERM SIGINT

load_options
if [[ -z "${TZ:-}" ]]; then
  TZ="$(api GET /info 2>/dev/null | jq -r '.data.timezone // empty' 2>/dev/null || true)"
  [[ -n "$TZ" ]] && export TZ
fi
info "Sauvegarde USB v${VERSION} — disque « ${DEVICE_LABEL} », dossier « ${FOLDER} », garder ${KEEP_LAST}, contrôle toutes les ${INTERVAL_MIN} min, notifications ${NOTIF_MODE}/${NOTIF_CHANNEL}, sauvegardes complètes seulement : ${ONLY_FULL}"
[[ -f "$STATE_FILE" ]] || echo '{}' >"$STATE_FILE"
KEEP_SLUGS=" "
STDIN_OPEN=1

while true; do
  run_cycle || true
  [[ "$RUN_ONCE" == "1" ]] && break
  # Attente ; une ligne « copy » envoyée via hassio.addon_stdin déclenche un passage immédiat
  cmd=""
  if [[ "$STDIN_OPEN" == "1" ]]; then
    read -r -t $(( INTERVAL_MIN * 60 )) cmd
    rc=$?
    if (( rc == 0 )); then
      cmd="$(printf '%s' "$cmd" | tr -d '"[:space:]' | tr '[:upper:]' '[:lower:]')"
      case "$cmd" in
        copy|copie|now|maintenant) info "Passage immédiat demandé" ;;
        test|testnotif) notify info "🔔 Sauvegarde USB" "Notification de test : la configuration fonctionne." ; info "Notification de test envoyée" ;;
        "") ;;
        *) warn "Commande inconnue : ${cmd} (utilise « copy » ou « test »)" ;;
      esac
    elif (( rc <= 128 )); then
      # fin de l'entrée standard : on passe en attente simple
      STDIN_OPEN=0
      sleep $(( INTERVAL_MIN * 60 )) & wait $! 2>/dev/null || true
    fi
  else
    sleep $(( INTERVAL_MIN * 60 )) & wait $! 2>/dev/null || true
  fi
done
