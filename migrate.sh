#!/usr/bin/env bash
# =====================================================================
#  FABIAN PERMADI TOOLS - CloudPanel Migration Wizard v3.0.0
#  Jalankan di VPS LAMA. Memindahkan data CloudPanel ke VPS BARU.
# =====================================================================
set -Eeuo pipefail

VERSION="3.0.0"

# ----------------------- Pengaturan -----------------------
PRESYNC_DB=1                                  # 1 = salin DB saat VPS lama masih hidup
HOME_EXCL=(--exclude=/ubuntu --exclude=/debian --exclude=/admin)
EXTRA_PATHS=()                                # contoh: EXTRA_PATHS=(/opt/app)
NOTIFY_URL="${NOTIFY_URL:-}"                  # webhook opsional (POST JSON {"text": ...})
STATE_DIR=/var/lib/cp-migrate
LOG_DIR=/var/log/cp-migrate
# ----------------------------------------------------------

if [ -t 1 ]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'
  MAG=$'\e[35m'; CYN=$'\e[36m'; BLD=$'\e[1m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
  RED=''; GRN=''; YEL=''; BLU=''; MAG=''; CYN=''; BLD=''; DIM=''; RST=''
fi
W=74

# ----------------------- Tampilan -----------------------
rep() { local s; s=$(printf "%${2}s" ""); printf '%s' "${s// /$1}"; }

panel() { # panel <warna> <judul> [baris...]
  local col=$1 title=$2 inner=$((W-4)) line seg
  shift 2
  printf '%s╭%s╮%s\n' "$col" "$(rep '─' $((W-2)))" "$RST"
  printf '%s│%s %s%-*s%s %s│%s\n' "$col" "$RST" "$BLD" "$inner" "$title" "$RST" "$col" "$RST"
  printf '%s├%s┤%s\n' "$col" "$(rep '─' $((W-2)))" "$RST"
  for line in "$@"; do
    if [ -z "$line" ]; then
      printf '%s│%s %-*s %s│%s\n' "$col" "$RST" "$inner" "" "$col" "$RST"
      continue
    fi
    while IFS= read -r seg; do
      printf '%s│%s %-*s %s│%s\n' "$col" "$RST" "$inner" "$seg" "$col" "$RST"
    done < <(printf '%s\n' "$line" | fold -s -w "$inner")
  done
  printf '%s╰%s╯%s\n' "$col" "$(rep '─' $((W-2)))" "$RST"
}

stage() { echo; echo "  ${MAG}${BLD}[$1/$2]${RST} ${BLD}$3${RST}"; echo "  ${DIM}$(rep '─' $((W-4)))${RST}"; }
ok()    { echo "  ${GRN}✔${RST} $*"; }
run()   { echo "  ${CYN}➜${RST} $*"; }
info()  { echo "  ${DIM}·${RST} $*"; }
warn()  { echo "  ${YEL}!${RST} $*"; }
fail()  { echo "  ${RED}✖${RST} $*" >&2; }
die()   { fail "$*"; exit 1; }

banner() {
  echo
  panel "$CYN" "FABIAN PERMADI TOOLS  -  CloudPanel Migration Wizard  v$VERSION" \
    "Memindahkan seluruh data CloudPanel dari VPS LAMA ke VPS BARU" \
    "dengan pengecekan, konfirmasi yang jelas, dan jalur pemulihan otomatis."
  echo
}

usage() {
  panel "$CYN" "Fabian Permadi Tools - Bantuan" \
    "Cara pakai:" \
    "  ./cloudpanel-migrate.sh                  Mode interaktif (menu)" \
    "  ./cloudpanel-migrate.sh --ip IP [opsi]   Mode langsung / otomatis" \
    "" \
    "Opsi:" \
    "  --ip IP       IP atau hostname VPS baru tujuan." \
    "  --port N      Port SSH VPS baru (default 22)." \
    "  --user NAMA   User SSH VPS baru (default root)." \
    "  --key FILE    Path private key SSH. Lebih aman daripada password." \
    "  --dry-run     Hanya cek kesiapan. Tidak mengubah apa pun." \
    "  --resume      Lanjutkan migrasi yang berhenti di tengah jalan." \
    "  --yes         Lewati konfirmasi. Hanya untuk otomasi, pakai hati-hati." \
    "  -h, --help    Tampilkan bantuan ini."
  exit 0
}

# ----------------------- Status global -----------------------
MODE=""; NEW_IP=""; NEW_PORT=22; NEW_USER=root; SSH_KEY=""
ASSUME_YES=0; RESUME=0; DRY_RUN=0
LOCAL_STOPPED=0; CURRENT="init"; SOCK="/tmp/.fpt-ssh-$$"
DOMAINS=(); NEW_FP=""; OLD_FP=""
NEED_MB=0; FREE_MB=0; VERSION_DIFF=0; DISK_LOW=0; EXISTING_SITES=0
TOTAL=10
RSYNC_E=""; SSH_OPTS=(); STATE=""; LOG=""

on_exit() {
  local rc=$?
  ssh -O exit -o ControlPath="$SOCK" "$NEW_USER@$NEW_IP" >/dev/null 2>&1 || true
  if (( rc != 0 )); then
    echo
    panel "$RED" "MIGRASI BERHENTI (kode $rc)" \
      "Tahap terakhir : $CURRENT" \
      "Log lengkap    : $LOG" \
      "Perbaiki penyebabnya, lalu jalankan lagi dan pilih menu [3] Lanjutkan."
    if (( LOCAL_STOPPED )); then
      warn "Menyalakan kembali service VPS LAMA agar situs tetap online..."
      svc_local start || warn "Gagal menyalakan service lokal. Cek manual."
    fi
    notify "GAGAL di tahap $CURRENT ($NEW_IP)"
  fi
  exit "$rc"
}
trap on_exit EXIT

# ----------------------- Argumen -----------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --ip)      NEW_IP=${2:?"--ip butuh nilai"};     shift 2 ;;
    --port)    NEW_PORT=${2:?"--port butuh nilai"}; shift 2 ;;
    --user)    NEW_USER=${2:?"--user butuh nilai"}; shift 2 ;;
    --key)     SSH_KEY=${2:?"--key butuh nilai"};   shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --resume)  RESUME=1;  shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    *) fail "Opsi tidak dikenal: $1"; usage ;;
  esac
done

# ----------------------- Prasyarat -----------------------
[ "$(id -u)" -eq 0 ] || die "Jalankan sebagai root: sudo -i"
command -v clpctl >/dev/null 2>&1 && [ -d /home/clp ] || die "CloudPanel tidak ditemukan di VPS ini."

mkdir -p "$LOG_DIR" "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || die "Ada migrasi lain yang sedang berjalan. Tunggu sampai selesai."
RUN_ID=$(date +%F-%H%M%S)
LOG="$LOG_DIR/run-$RUN_ID.log"
exec > >(tee -a "$LOG") 2>&1

# ----------------------- Input -----------------------
notify() {
  [ -n "$NOTIFY_URL" ] || return 0
  curl -s -m 10 -X POST -H 'Content-Type: application/json' \
       -d "{\"text\":\"[Fabian Permadi Tools] $1\"}" "$NOTIFY_URL" >/dev/null || true
}

menu() {
  banner
  panel "$BLU" "Menu Utama" \
    "[1] Cek kesiapan (dry-run)" \
    "    Cek koneksi, versi, disk, dan daftar situs. Tidak mengubah apa pun. Sangat disarankan dijalankan dulu." \
    "[2] Migrasi lengkap" \
    "    Pindahkan semua data ke VPS baru. Isi CloudPanel di VPS baru akan DITIMPA." \
    "[3] Lanjutkan migrasi yang gagal" \
    "    Melanjutkan dari tahap terakhir yang berhasil, tanpa mengulang dari awal." \
    "[4] Keluar" \
    "    Tutup tool tanpa mengubah apa pun."
  local c
  while :; do
    read -rp "  Pilih [1-4]: " c
    case "$c" in
      1) DRY_RUN=1; return ;;
      2) return ;;
      3) RESUME=1; return ;;
      4) echo "  Sampai jumpa."; exit 0 ;;
      *) warn "Masukkan angka 1 sampai 4." ;;
    esac
  done
}

ask_target() {
  panel "$BLU" "Data VPS baru (tujuan)" \
    "IP / hostname : alamat VPS baru, contoh 203.0.113.10" \
    "Port SSH      : biasanya 22. Sesuaikan dengan konfigurasi VPS baru." \
    "User SSH      : biasanya root." \
    "SSH key       : file kunci login, lebih aman daripada password. Kosongkan untuk memakai key default di ~/.ssh."
  echo
  while :; do
    read -rp "  IP / hostname VPS baru : " NEW_IP
    [[ "$NEW_IP" =~ ^[A-Za-z0-9.-]+$ ]] && break
    warn "Format tidak valid. Contoh: 203.0.113.10"
  done
  local v
  read -rp "  Port SSH [22]          : " v; NEW_PORT=${v:-22}
  [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || die "Port harus berupa angka."
  read -rp "  User SSH [root]        : " v; NEW_USER=${v:-root}
  read -rp "  Path SSH key (opsional): " v; SSH_KEY=$v
  if [ -n "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ]; then die "File key tidak ditemukan: $SSH_KEY"; fi
}

setup_target() {
  SSH_OPTS=(-p "$NEW_PORT" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30
            -o ServerAliveCountMax=20 -o ConnectTimeout=15
            -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=3h)
  if [ -n "$SSH_KEY" ]; then SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes); fi
  RSYNC_E="ssh ${SSH_OPTS[*]}"
  STATE="$STATE_DIR/${NEW_IP}.state"
  if (( RESUME )); then
    [ -f "$STATE" ] || die "Tidak ada catatan migrasi untuk $NEW_IP. Jalankan migrasi lengkap dulu."
    info "Mode lanjutkan: tahap yang sudah selesai akan dilewati."
  elif (( ! DRY_RUN )); then
    : > "$STATE"
  fi
}

R() { ssh "${SSH_OPTS[@]}" "$NEW_USER@$NEW_IP" "$@"; }

# ----------------------- Konfirmasi -----------------------
ask_typed() { # ask_typed <kata>
  if [ "$ASSUME_YES" = 1 ]; then info "(--yes) konfirmasi dilewati."; return 0; fi
  local a
  read -rp "  Ketik ${BLD}$1${RST} untuk melanjutkan, atau Enter untuk batal: " a
  [ "$a" = "$1" ] || die "Dibatalkan oleh pengguna. Tidak ada perubahan yang dibuat."
}

ask_yn() { # ask_yn "<pertanyaan>" <Y|N>
  local def=$2 a hint
  if [ "$def" = Y ]; then hint="Y/n"; else hint="y/N"; fi
  if [ "$ASSUME_YES" = 1 ]; then
    a=$def; info "(--yes) memakai pilihan default: $def"
  else
    read -rp "  $1 [$hint]: " a; a=${a:-$def}
  fi
  [[ "$a" =~ ^[Yy]$ ]]
}

# ----------------------- Koneksi & pemeriksaan -----------------------
connect_new() {
  run "Menguji login SSH ke $NEW_USER@$NEW_IP:$NEW_PORT ..."
  if ! R true 2>/dev/null; then
    fail "Tidak bisa login SSH ke VPS baru."
    info "Penyebab umum: IP atau port salah, atau SSH key belum dipasang di VPS baru."
    info "Pasang key dengan: ssh-copy-id -p $NEW_PORT $NEW_USER@$NEW_IP"
    die "Koneksi gagal."
  fi
  ok "Koneksi SSH berhasil."
  if ! R 'command -v clpctl >/dev/null && [ -d /home/clp ]' 2>/dev/null; then
    die "CloudPanel belum terpasang di VPS baru. Pasang dulu dengan versi yang sama seperti VPS lama."
  fi
  ok "CloudPanel terdeteksi di VPS baru."
  if [ "$(R 'id -u' 2>/dev/null)" != 0 ]; then die "Login VPS baru harus sebagai root."; fi
}

fingerprint() {
  local os nginx db php
  os=$(. /etc/os-release; echo "$ID $VERSION_ID")
  nginx=$(nginx -v 2>&1 | grep -oE '[0-9.]+' | head -1 || true)
  db=$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-MariaDB)?' | head -1 || true)
  php=$(ls /etc/php 2>/dev/null | tr '\n' ' ' || true)
  printf 'os=%s\nnginx=%s\ndb=%s\nphp=%s\n' "$os" "$nginx" "$db" "$php"
}

dblist() {
  mysql -N -e 'SHOW DATABASES' 2>/dev/null \
    | grep -vE '^(information_schema|performance_schema|mysql|sys)$' | sort || true
}

preflight() {
  OLD_FP=$(fingerprint)
  NEW_FP=$(R "$(declare -f fingerprint); fingerprint")

  echo
  info "Perbandingan versi (perlu sama agar aman):"
  local k v rv
  while IFS='=' read -r k v; do
    rv=$(grep "^$k=" <<<"$NEW_FP" | cut -d= -f2- || true)
    if [ "$v" = "$rv" ]; then
      echo "    ${GRN}✔${RST} $k  lama: ${v:-?}  baru: ${rv:-?}"
    else
      echo "    ${YEL}!${RST} $k  lama: ${v:-?}  baru: ${rv:-?}  ${YEL}(BEDA)${RST}"
      VERSION_DIFF=1
    fi
  done <<<"$OLD_FP"

  local need_b free_b
  need_b=$(du -sb /home /var/lib/mysql 2>/dev/null | awk '{s+=$1} END{print s+0}')
  free_b=$(R "df -B1 --output=avail / | tail -1" 2>/dev/null | tr -d ' ' || true)
  NEED_MB=$(( ${need_b:-0} / 1048576 ))
  FREE_MB=$(( ${free_b:-0} / 1048576 ))
  if (( FREE_MB < NEED_MB * 12 / 10 )); then DISK_LOW=1; fi

  mapfile -t DOMAINS < <(
    for p in /home/*/htdocs/*/; do
      [ -d "$p" ] || continue
      case "$p" in /home/clp/*) continue ;; esac
      basename "$p"
    done
  )

  EXISTING_SITES=$(R 'ls -d /home/*/htdocs/*/ 2>/dev/null | grep -vc "^/home/clp/"' 2>/dev/null | tr -dc '0-9' || true)
  EXISTING_SITES=${EXISTING_SITES:-0}

  info "Data yang akan dipindah : $NEED_MB MB"
  info "Disk kosong VPS baru    : $FREE_MB MB"
  info "Situs terdeteksi        : ${#DOMAINS[@]}"
  info "Situs yang sudah ada di VPS baru: $EXISTING_SITES"
  if (( DISK_LOW )); then warn "Disk VPS baru kurang. Butuh minimal 120% dari ukuran data."; fi
}

report_dryrun() {
  local versi="sama"; (( VERSION_DIFF )) && versi="BEDA (periksa lagi)"
  local disk="cukup"; (( DISK_LOW )) && disk="KURANG"
  echo
  panel "$GRN" "HASIL CEK KESIAPAN (DRY-RUN)" \
    "Tidak ada perubahan yang dibuat." \
    "Koneksi SSH      : OK" \
    "Versi            : $versi" \
    "Disk             : $disk  ($FREE_MB MB kosong, butuh sekitar $((NEED_MB*12/10)) MB)" \
    "Situs terdeteksi : ${#DOMAINS[@]}" \
    "" \
    "Jika semua sudah sesuai, jalankan migrasi lengkap (menu 2)."
}

plan_confirm() {
  echo
  if (( VERSION_DIFF )); then warn "Versi OS/nginx/DB/PHP berbeda. Risiko meningkat."; fi
  if (( DISK_LOW )); then die "Disk VPS baru kurang. Perbesar disk lalu coba lagi."; fi
  panel "$RED" "KONFIRMASI: MIGRASI AKAN DIMULAI" \
    "Yang AKAN terjadi:" \
    "  - Isi CloudPanel di VPS BARU ($NEW_IP) DITIMPA dengan data VPS LAMA." \
    "  - ${#DOMAINS[@]} situs, database, dan konfigurasi nginx/PHP/SSL disalin." \
    "  - Service VPS LAMA dihentikan sebentar saat sinkronisasi terakhir (downtime)." \
    "" \
    "Yang TIDAK akan terjadi:" \
    "  - DNS tidak diubah otomatis. Itu dilakukan manual setelah verifikasi." \
    "  - VPS lama tidak dihapus." \
    "" \
    "Jika gagal di tengah jalan:" \
    "  - Service VPS lama dinyalakan lagi otomatis." \
    "  - Jalankan lagi dengan menu [3] Lanjutkan setelah masalah diperbaiki."
  if (( EXISTING_SITES > 0 )); then
    warn "VPS baru sudah berisi $EXISTING_SITES situs. Situs tersebut akan HILANG."
  fi
  ask_typed "YA"
}

# ----------------------- Sinkronisasi -----------------------
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
svc_local()  { svc_script | bash -s -- "$1"; }
svc_remote() { svc_script | R bash -s -- "$1"; }

rs() { # rs <path> [opsi rsync tambahan...]
  local p=$1; shift
  [ -e "$p" ] || { warn "Lewati $p (tidak ada)"; return 0; }
  R "mkdir -p '$p'"
  info "Sinkronisasi $p"
  local rc=0
  rsync -aHAX --numeric-ids --delete --info=progress2 --human-readable \
        -e "$RSYNC_E" "$@" "$p/" "$NEW_USER@$NEW_IP:$p/" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then die "rsync $p gagal (kode $rc)"; fi
}

sync_users() {
  local T="/tmp/mig_users_$$"; rm -rf "$T"; mkdir -p "$T"
  awk -F: '$3>=1000 && $3<60000' /etc/group  > "$T/group.txt"
  awk -F: '$3>=1000 && $3<60000' /etc/passwd > "$T/passwd.txt"
  awk -F: 'NR==FNR{g[$1]=1;next} ($1 in g)' "$T/group.txt"  /etc/gshadow > "$T/gshadow.txt"
  awk -F: 'NR==FNR{u[$1]=1;next} ($1 in u)' "$T/passwd.txt" /etc/shadow  > "$T/shadow.txt"
  rsync -a -e "$RSYNC_E" "$T/" "$NEW_USER@$NEW_IP:/tmp/mig_users/"
  rm -rf "$T"
  R 'bash -s' <<'EOF'
set -e
cd /tmp/mig_users
while IFS=: read -r n _ gid _; do
  if getent group "$n" >/dev/null; then
    [ "$(getent group "$n" | cut -d: -f3)" = "$gid" ] || { echo "KONFLIK group $n"; exit 1; }
  else
    getent group "$gid" >/dev/null && { echo "KONFLIK gid $gid"; exit 1; }
    grep "^$n:" group.txt   >> /etc/group
    grep "^$n:" gshadow.txt >> /etc/gshadow || true
  fi
done < group.txt
while IFS=: read -r n _ uid _; do
  if getent passwd "$n" >/dev/null; then
    [ "$(getent passwd "$n" | cut -d: -f3)" = "$uid" ] || { echo "KONFLIK user $n"; exit 1; }
  else
    getent passwd "$uid" >/dev/null && { echo "KONFLIK uid $uid"; exit 1; }
    grep "^$n:" passwd.txt >> /etc/passwd
    grep "^$n:" shadow.txt >> /etc/shadow || true
  fi
done < passwd.txt
rm -rf /tmp/mig_users
EOF
  ok "User dan group situs tersalin."
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

sync_pre()   { info "VPS lama masih hidup, tidak ada downtime di tahap ini."; sync_all pre; }
stop_old()   { info "Menghentikan service VPS lama. Downtime dimulai."; svc_local stop; LOCAL_STOPPED=1; }
sync_final() { info "Hanya selisih data terakhir yang disalin."; sync_users; sync_all final; sync; }

start_new() {
  R 'nginx -t' >/dev/null 2>&1 || die "Konfigurasi nginx di VPS baru gagal (nginx -t)."
  svc_remote start
  sleep 5
  svc_remote status
  local code
  code=$(R "curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/" 2>/dev/null || true)
  if [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]; then
    ok "Panel CloudPanel di VPS baru merespons (HTTP $code)."
  else
    die "Panel CloudPanel di VPS baru tidak merespons."
  fi
}

# ----------------------- Verifikasi -----------------------
verify_db() {
  local a b
  a=$(dblist)
  b=$(R "$(declare -f dblist); dblist" 2>/dev/null || true)
  if [ "$a" = "$b" ]; then
    ok "Daftar database sama ($(grep -c . <<<"$a" || true) database)."
  else
    warn "Daftar database BEDA:"
    diff <(echo "$a") <(echo "$b") || true
  fi
}

verify_sites() {
  if (( ${#DOMAINS[@]} == 0 )); then info "Tidak ada situs terdeteksi. Verifikasi situs dilewati."; return 0; fi
  local d code good=0 bad=0
  for d in "${DOMAINS[@]}"; do
    code=$(curl -sk -o /dev/null -m 15 -w '%{http_code}' --resolve "$d:443:$NEW_IP" "https://$d/" || true)
    if [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]; then
      ok "$d  ->  HTTP $code"; good=$((good+1))
    else
      warn "$d  ->  tidak merespons (${code:-timeout})"; bad=$((bad+1))
    fi
  done
  info "Hasil: $good berhasil, $bad bermasalah."
  (( bad == 0 )) || warn "Perbaiki situs yang bermasalah sebelum mengubah DNS."
}

verify_all() {
  verify_db
  verify_sites
  local old_ip
  old_ip=$(curl -4 -s -m 5 ifconfig.me || true)
  if [ -n "$old_ip" ]; then
    info "Mencari sisa IP lama ($old_ip) di konfigurasi VPS baru..."
    R "grep -rIl --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git '$old_ip' /etc/nginx /home/clp 2>/dev/null | head -20" \
      2>/dev/null | sed 's/^/      ditemukan: /' || true
  fi
}

finish_old() {
  LOCAL_STOPPED=0
  echo
  if ask_yn "Biarkan VPS LAMA tetap mati? (disarankan, agar tidak ada data ganda)" Y; then
    ok "VPS lama tetap mati."
  else
    svc_local start
    warn "VPS lama dinyalakan lagi. Pastikan tidak ada data masuk ke dua VPS."
  fi
}

# ----------------------- Pengatur tahap -----------------------
step() { # step <id> <nomor> <judul> <fungsi>
  CURRENT=$1
  if (( RESUME )) && grep -qx "$1" "$STATE"; then
    ok "[$2/$TOTAL] $3 - sudah selesai sebelumnya, dilewati"
    return 0
  fi
  stage "$2" "$TOTAL" "$3"
  "$4"
  echo "$1" >> "$STATE"
  ok "$3 - selesai"
}

show_plan() {
  panel "$BLU" "Apa yang akan dilakukan" \
    "1. Cek koneksi dan kesiapan VPS baru" \
    "2. Konfirmasi (kamu mengetik YA)" \
    "3. Salin user dan group situs" \
    "4. Pre-sync: salin data besar selagi VPS lama masih hidup" \
    "5. Hentikan VPS lama (downtime dimulai)" \
    "6. Sync final: salin selisih data terakhir" \
    "7. Nyalakan service di VPS baru" \
    "8. Verifikasi database, situs, dan panel" \
    "9. Tentukan apakah VPS lama tetap dimatikan" \
    "10. Selesai. Ubah DNS secara manual"
}

# ----------------------- Eksekusi -----------------------
main() {
  if [ -z "$NEW_IP" ]; then
    [ -t 0 ] || die "Mode non-interaktif butuh --ip. Lihat --help."
    if (( ! RESUME && ! DRY_RUN )); then menu; else
      banner
      [ "$DRY_RUN" = 1 ] && MODE=dryrun || MODE=resume
    fi
    if [ "${MODE:-}" = "" ]; then :; fi
    ask_target
  else
    banner
  fi

  setup_target

  stage 1 "$TOTAL" "Koneksi ke VPS baru"
  connect_new
  stage 2 "$TOTAL" "Pemeriksaan kesiapan"
  preflight

  if (( DRY_RUN )); then
    report_dryrun
    exit 0
  fi

  if (( ! RESUME )); then show_plan; fi

  # Tahap utama. LOCAL_STOPPED dipulihkan jika sebelumnya sudah dihentikan.
  if (( RESUME )) && grep -qx stop-old "$STATE" && ! grep -qx finish-old "$STATE"; then
    LOCAL_STOPPED=1
  fi

  step confirm     3  "Konfirmasi"                     plan_confirm
  step copy-users  4  "Salin user dan group situs"     sync_users
  step presync     5  "Pre-sync data (VPS lama hidup)" sync_pre
  step stop-old    6  "Hentikan VPS lama"              stop_old
  step final-sync  7  "Sync final"                     sync_final
  step start-new   8  "Nyalakan VPS baru"              start_new
  step verify      9  "Verifikasi"                     verify_all
  step finish-old  10 "Tentukan status VPS lama"       finish_old

  echo
  panel "$GRN" "MIGRASI SELESAI" \
    "Data sudah berada di VPS baru: $NEW_IP" \
    "" \
    "Langkah berikutnya:" \
    "  1. Ubah DNS semua domain ke $NEW_IP." \
    "  2. Setelah DNS berpindah, cek ulang situs dari luar." \
    "  3. Perbarui SSL Let's Encrypt jika diperlukan." \
    "" \
    "Log lengkap: $LOG"
  notify "SELESAI ke $NEW_IP, ${#DOMAINS[@]} situs"
}

main
