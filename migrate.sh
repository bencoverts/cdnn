#!/usr/bin/env bash
# =====================================================================
#  cloudpanel-migrate.sh
#  Jalankan di VPS LAMA. Memindahkan SELURUH data CloudPanel ke VPS BARU:
#  situs, user situs, database MySQL/MariaDB (+user DB), phpMyAdmin,
#  konfigurasi nginx, pool PHP-FPM, SSL, cron job, FTP, dan DB CloudPanel.
#
#  Syarat VPS BARU:
#    - OS sama (Ubuntu 24), CloudPanel SUDAH terinstall (versi & DB engine
#      sama dengan VPS lama), belum ada situs yang dibuat
#    - Bisa login SSH sebagai root (password atau SSH key)
# =====================================================================
set -Eeuo pipefail

### ---------------- Pengaturan (boleh diubah) ----------------
PRESYNC_DB=1   # 1 = salin database dulu saat masih hidup -> downtime jauh lebih singkat
# User bawaan provider di VPS baru yang tidak boleh terhapus saat sync /home
HOME_EXCL=(--exclude=/ubuntu --exclude=/debian --exclude=/admin)
# Path tambahan yang ingin ikut dipindah, contoh: EXTRA_PATHS=(/opt/app /etc/redis)
EXTRA_PATHS=()
### -----------------------------------------------------------

LOG="/root/cp-migrate-$(date +%F-%H%M).log"
exec > >(tee -a "$LOG") 2>&1

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
log()  { echo "${C_B}[*]${C_0} $*"; }
ok()   { echo "${C_G}[OK]${C_0} $*"; }
warn() { echo "${C_Y}[!]${C_0} $*"; }
die()  { echo "${C_R}[X]${C_0} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Jalankan sebagai root (sudo -i)."
command -v clpctl >/dev/null 2>&1 && [ -d /home/clp ] || die "CloudPanel tidak ditemukan di VPS ini."

LOCAL_STOPPED=0
SOCK="/tmp/.mig-ssh-$$"

# ---------------------------------------------------------------
# Script kontrol service (dijalankan lokal & remote lewat bash -s)
# ---------------------------------------------------------------
svc_script() { cat <<'EOS'
action=$1
units=()
for u in nginx clp-nginx clp-agent clp-php-fpm proftpd; do
  systemctl cat "$u" >/dev/null 2>&1 && units+=("$u")
done
for u in $(systemctl list-unit-files --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}'); do
  units+=("$u")
done
db=""
for d in mysql mariadb; do
  systemctl cat "$d" >/dev/null 2>&1 && { db=$d; break; }
done
case "$action" in
  stop)
    [ ${#units[@]} -gt 0 ] && systemctl stop "${units[@]}" 2>/dev/null
    [ -n "$db" ] && systemctl stop "$db"
    true ;;
  start)
    [ -n "$db" ] && systemctl start "$db"
    [ ${#units[@]} -gt 0 ] && systemctl start "${units[@]}" 2>/dev/null
    true ;;
  status)
    for u in $db "${units[@]}"; do printf '  %-30s %s\n' "$u" "$(systemctl is-active "$u")"; done ;;
esac
EOS
}

cleanup() {
  local rc=$?
  if [ $rc -ne 0 ] && [ "$LOCAL_STOPPED" -eq 1 ]; then
    warn "Script gagal. Menyalakan kembali service di VPS LAMA..."
    svc_script | bash -s -- start || true
  fi
  [ -n "${NEW_IP:-}" ] && ssh -O exit -o ControlPath="$SOCK" "${NEW_USER:-root}@${NEW_IP}" 2>/dev/null || true
  [ $rc -ne 0 ] && warn "Log lengkap: $LOG"
  return $rc
}
trap cleanup EXIT

# ---------------------------------------------------------------
# FORM INPUT
# ---------------------------------------------------------------
echo
echo "==============================================="
echo "   MIGRASI CLOUDPANEL: VPS LAMA  ->  VPS BARU"
echo "==============================================="
read -rp  "IP VPS baru            : " NEW_IP
[ -n "$NEW_IP" ] || die "IP VPS baru wajib diisi."
read -rp  "Port SSH VPS baru [22] : " NEW_PORT;  NEW_PORT=${NEW_PORT:-22}
read -rp  "User SSH [root]        : " NEW_USER;  NEW_USER=${NEW_USER:-root}
read -rsp "Password SSH (kosong = pakai SSH key): " NEW_PASS; echo

log "Menyiapkan tool (rsync, sshpass)..."
export DEBIAN_FRONTEND=noninteractive
command -v rsync   >/dev/null || apt-get install -y -qq rsync   >/dev/null
[ -z "$NEW_PASS" ] || command -v sshpass >/dev/null || apt-get install -y -qq sshpass >/dev/null

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=$SOCK -o ControlPersist=3h -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -p $NEW_PORT"
R() { ssh $SSH_OPTS "$NEW_USER@$NEW_IP" "$@"; }

log "Menghubungkan ke $NEW_USER@$NEW_IP:$NEW_PORT ..."
if [ -n "$NEW_PASS" ]; then
  SSHPASS="$NEW_PASS" sshpass -e ssh $SSH_OPTS "$NEW_USER@$NEW_IP" true || die "Login SSH gagal."
else
  ssh $SSH_OPTS "$NEW_USER@$NEW_IP" true || die "Login SSH gagal (cek SSH key)."
fi
unset NEW_PASS
ok "Terhubung."

# ---------------------------------------------------------------
# PREFLIGHT
# ---------------------------------------------------------------
[ "$(R 'id -u')" = "0" ] || die "VPS baru: harus login sebagai root."
R 'command -v clpctl >/dev/null && [ -d /home/clp ]' || die "VPS baru: CloudPanel belum terinstall. Install dulu (versi & DB engine sama dengan VPS lama)."
R 'command -v rsync >/dev/null || { apt-get update -qq && apt-get install -y -qq rsync; }' >/dev/null

L_OS=$(. /etc/os-release; echo "$ID $VERSION_ID")
R_OS=$(R '. /etc/os-release; echo "$ID $VERSION_ID"')
[ "$L_OS" = "$R_OS" ] || die "OS beda: lama='$L_OS' baru='$R_OS'. Harus sama."

dbver() { mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-MariaDB)?' | head -1; }
L_DB=$(dbver)
R_DB=$(R "$(declare -f dbver); dbver")
log "Versi database  lama: ${L_DB:-?}   baru: ${R_DB:-?}"
if [ "$L_DB" != "$R_DB" ]; then
  warn "Versi database BEDA. Salinan fisik database bisa gagal start kalau VPS baru lebih LAMA."
  read -rp "Tetap lanjut? [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]] || die "Dibatalkan."
fi

missing=$(comm -23 <(ls /etc/php 2>/dev/null | sort) <(R 'ls /etc/php 2>/dev/null | sort') || true)
[ -z "$missing" ] || die "VPS baru belum punya versi PHP: $(echo $missing). Install via CloudPanel dulu."

OLD_IP=$(curl -4 -s --max-time 5 ifconfig.me || true)

echo
log "Ringkasan data yang akan dipindah:"
du -sh /home /var/lib/mysql 2>/dev/null | sed 's/^/    /'
echo "    Sisa disk VPS baru: $(R "df -h / | awk 'NR==2{print \$4}'")"
echo
warn "SEMUA isi CloudPanel di VPS BARU ($NEW_IP) akan DITIMPA dengan data VPS LAMA."
warn "VPS LAMA akan downtime singkat saat sync final."
read -rp "Ketik YA untuk mulai: " confirm
[ "$confirm" = "YA" ] || die "Dibatalkan."

# ---------------------------------------------------------------
# FUNGSI SYNC
# ---------------------------------------------------------------
rs() { # rs <path> [opsi rsync tambahan...]
  local p=$1; shift
  [ -e "$p" ] || { warn "Lewati $p (tidak ada di VPS lama)"; return 0; }
  R "mkdir -p '$p'"
  log "Sync $p"
  rsync -aHAX --delete --info=progress2 --human-readable \
        -e "ssh $SSH_OPTS" "$@" "$p/" "$NEW_USER@$NEW_IP:$p/" || [ $? -eq 24 ]
}

sync_users() { # salin user & group situs (uid/gid >= 1000) beserta password hash
  local T="/tmp/mig_users_$$"; rm -rf "$T"; mkdir -p "$T"
  awk -F: '$3>=1000 && $3<60000' /etc/group  > "$T/group.txt"
  awk -F: '$3>=1000 && $3<60000' /etc/passwd > "$T/passwd.txt"
  awk -F: 'NR==FNR{g[$1]=1;next} ($1 in g)' "$T/group.txt"  /etc/gshadow > "$T/gshadow.txt"
  awk -F: 'NR==FNR{u[$1]=1;next} ($1 in u)' "$T/passwd.txt" /etc/shadow  > "$T/shadow.txt"
  rsync -a -e "ssh $SSH_OPTS" "$T/" "$NEW_USER@$NEW_IP:/tmp/mig_users/"
  rm -rf "$T"
  R 'bash -s' <<'EOF'
set -e
cd /tmp/mig_users
while IFS=: read -r n _ gid _; do
  if getent group "$n" >/dev/null; then
    [ "$(getent group "$n" | cut -d: -f3)" = "$gid" ] || { echo "KONFLIK group $n (gid beda)"; exit 1; }
  else
    getent group "$gid" >/dev/null && { echo "KONFLIK gid $gid sudah dipakai group lain"; exit 1; }
    grep "^$n:" group.txt   >> /etc/group
    grep "^$n:" gshadow.txt >> /etc/gshadow || true
  fi
done < group.txt
while IFS=: read -r n _ uid _; do
  if getent passwd "$n" >/dev/null; then
    [ "$(getent passwd "$n" | cut -d: -f3)" = "$uid" ] || { echo "KONFLIK user $n (uid beda)"; exit 1; }
  else
    getent passwd "$uid" >/dev/null && { echo "KONFLIK uid $uid sudah dipakai user lain"; exit 1; }
    grep "^$n:" passwd.txt >> /etc/passwd
    grep "^$n:" shadow.txt >> /etc/shadow || true
  fi
done < passwd.txt
rm -rf /tmp/mig_users
EOF
}

sync_all() { # $1 = pre | final
  local dbx=()
  [ "$1" = final ] && [ "$PRESYNC_DB" = 1 ] && dbx=(--checksum)
  rs /home "${HOME_EXCL[@]}"
  rs /etc/nginx
  rs /etc/php
  rs /etc/letsencrypt
  rs /etc/proftpd
  rs /etc/mysql
  rs /var/spool/cron/crontabs
  if [ "$1" = final ] || [ "$PRESYNC_DB" = 1 ]; then
    rs /var/lib/mysql --exclude=auto.cnf --exclude='*.pid' --exclude='*.sock' "${dbx[@]}"
  fi
  local p
  for p in "${EXTRA_PATHS[@]}"; do rs "$p"; done
}

# ---------------------------------------------------------------
# EKSEKUSI
# ---------------------------------------------------------------
log "[1/6] Mematikan service CloudPanel & database di VPS BARU..."
svc_script | R 'bash -s -- stop'

log "[2/6] Menyalin user & group situs..."
sync_users

log "[3/6] Pre-sync (VPS lama masih hidup, tidak ada downtime)..."
sync_all pre

log "[4/6] Mematikan service di VPS LAMA (downtime mulai)..."
svc_script | bash -s -- stop
LOCAL_STOPPED=1

log "[5/6] Sync final (hanya selisih terakhir)..."
sync_users
sync_all final
sync

log "[6/6] Menyalakan service di VPS BARU..."
R 'nginx -t' || warn "nginx -t di VPS baru GAGAL, cek konfigurasi."
svc_script | R 'bash -s -- start'
sleep 5
echo "Status service VPS baru:"
svc_script | R 'bash -s -- status'
CODE=$(R "curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/" || true)
log "Tes panel CloudPanel di VPS baru (port 8443): HTTP ${CODE:-?}"

if [ -n "$OLD_IP" ]; then
  log "Mencari sisa IP lama ($OLD_IP) di konfigurasi VPS baru..."
  R "grep -rIl --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git '$OLD_IP' /etc/nginx /home/clp 2>/dev/null | head -20" \
    | sed 's/^/    ditemukan: /' || true
fi

LOCAL_STOPPED=0
echo
read -rp "Biarkan service VPS LAMA tetap mati (disarankan, cegah data ganda)? [Y/n]: " keep
if [[ "$keep" =~ ^[Nn]$ ]]; then
  svc_script | bash -s -- start
  warn "VPS lama dinyalakan lagi. Jangan sampai ada data baru masuk ke dua VPS sekaligus."
else
  LOCAL_STOPPED=2
fi

echo
ok "SELESAI. Log: $LOG"
cat <<NEXT

Langkah berikutnya:
  1. Arahkan DNS semua domain ke IP VPS baru: $NEW_IP
  2. Tes dulu lewat file hosts / curl --resolve sebelum ganti DNS
  3. Kalau SSL Let's Encrypt perlu diperbarui, renew setelah DNS menunjuk ke VPS baru
  4. Login CloudPanel di https://$NEW_IP:8443 pakai akun yang sama dengan VPS lama
NEXT
