#!/usr/bin/env bash
# ------------------------------------------------------------------
# LineageOS előkészítő, burn és flash script
# Eszközök: Odroid C4 és Banana Pi M5 – tablet (alapértelmezett) és Android TV változat
# Host: Ubuntu 24.04.x LTS, x86_64, sudo joggal rendelkező (nem root) user
#
# Súgó: ./lineage_prep.sh --help
# ------------------------------------------------------------------
set -euo pipefail

PROJECT_DIR="${HOME}/lineage_project"
API="https://download.lineageos.org/api/v2/devices"
AML_REPO="https://github.com/radxa/aml-flash-tool.git"
VERIFIER_REPO="https://github.com/LineageOS/update_verifier.git"
VERIFIER_DIR="${PROJECT_DIR}/update_verifier"
AML_DIR="${PROJECT_DIR}/aml-flash-tool"

# LineageOS codename -> helyi mappanév
# Tablet: *_tab   |   Android TV: codename utótag nélkül
declare -A DEVICES=(
    [odroidc4_tab]="odroid_c4_tab"  [m5_tab]="banana_m5_tab"
    [odroidc4]="odroid_c4_tv"       [m5]="banana_m5_tv"
)
declare -A DEVICE_DESC=(
    [odroidc4_tab]="Odroid C4 – Tablet"      [m5_tab]="Banana Pi M5 – Tablet"
    [odroidc4]="Odroid C4 – Android TV"      [m5]="Banana Pi M5 – Android TV"
)

# Add-onok (MindTheGapps)
ADDON_DIR="${PROJECT_DIR}/addons"          # letöltött GApps
EXTRA_ADDON_DIR="${ADDON_DIR}/extra"       # ide tehetsz saját zip-eket
# LineageOS fő verzió -> Android verzió (MindTheGapps repó elnevezéshez)
declare -A LOS_TO_ANDROID=( [20]="13.0.0" [21]="14.0.0" [22]="15.0.0" [23]="16.0.0" )
# Eszköz -> MindTheGapps változat
# (mind 32 bites 'arm' Android userspace; a TV változat ATV GApps-ot kap)
declare -A GAPPS_VARIANT=(
    [odroidc4_tab]="arm"  [m5_tab]="arm"
    [odroidc4]="arm-ATV"  [m5]="arm-ATV"
)
NO_GAPPS=0

RED=$'\e[1;31m'; GRN=$'\e[1;32m'; YEL=$'\e[1;33m'; CYN=$'\e[1;36m'; RST=$'\e[0m'

log()  { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ==================================================================
#  Interaktív segédfüggvények
# ==================================================================

# Nagy, feltűnő figyelmeztetés + hangjelzés, Enterre vár
reboot_alert() {
    local title="$1"; shift
    printf '\a'
    echo
    echo "${RED}╔══════════════════════════════════════════════════════════════╗${RST}"
    printf '%s║  ⚠  %-57s║%s\n' "$RED" "$title" "$RST"
    echo "${RED}╚══════════════════════════════════════════════════════════════╝${RST}"
    local line
    for line in "$@"; do echo "   ${YEL}➜${RST} $line"; done
    echo
    read -rp "   Ha megvagy, nyomj Entert... " _
}

# Sima teendő (nem újraindítás), Enterre vár
todo() {
    echo
    echo "${CYN}── TEENDŐ AZ ESZKÖZÖN ─────────────────────────────────────────${RST}"
    local line
    for line in "$@"; do echo "   ${CYN}➜${RST} $line"; done
    read -rp "   Ha megvagy, nyomj Entert... " _
}

# igen/nem kérdés
ask_yes() {
    local ans
    read -rp "$1 [i/N] " ans
    [[ "$ans" =~ ^[iIyY]$ ]]
}

# Vár egy feltétel teljesülésére (pl. USB eszköz megjelenése), időkorláttal
#   wait_for "leírás" <parancs...>
wait_for() {
    local desc="$1"; shift
    local timeout=180 waited=0
    local spin='|/-\' i=0
    while true; do
        if "$@" >/dev/null 2>&1; then
            printf '\r%s[+]%s %s – megvan.            \n' "$GRN" "$RST" "$desc"
            return 0
        fi
        printf '\r   Várakozás: %s %s (%ss) ' "$desc" "${spin:i++%4:1}" "$waited"
        sleep 1
        (( ++waited ))
        if (( waited >= timeout )); then
            echo
            warn "Nem jelent meg: $desc"
            local ans
            read -rp "   [Ú]jra várok / [K]ihagyom / [M]egszakít? " ans
            case "$ans" in
                [kK]) return 0 ;;
                [mM]) die "Megszakítva." ;;
                *)    waited=0 ;;
            esac
        fi
    done
}

# Detektorok
# A kimenetet előbb változóba mentjük: 'set -o pipefail' mellett a 'cmd | grep -q'
# hamis hibát adhat (SIGPIPE), a 'fastboot getvar' pedig eszköz nélkül örökké várna.
is_amlogic_burn() { local o; o=$(lsusb -d 1b8e: 2>/dev/null) || return 1; [[ -n "$o" ]]; }
# Az Amlogic u-boot "Android Fastboot"-ot ír (nagy F), ezért csak azt nézzük, van-e sor.
is_fastboot()     { local o; o=$(timeout 5 fastboot devices 2>/dev/null) || return 1; [[ "$o" == *$'\t'* ]]; }
is_sideload()     { local o; o=$(adb devices 2>/dev/null) || return 1; grep -qP '\tsideload$' <<<"$o"; }
is_adb_android()  { local o; o=$(adb devices 2>/dev/null) || return 1; grep -qP '\tdevice$' <<<"$o"; }
is_userspace()    { local o; o=$(timeout 5 fastboot getvar is-userspace 2>&1) || true; [[ "$o" == *"is-userspace: yes"* ]]; }
is_bl_fastboot()  { is_fastboot && ! is_userspace; }   # bootloader (u-boot) fastboot
is_fastbootd()    { is_fastboot && is_userspace; }     # recovery-s fastbootd

# ==================================================================
#  PREP: csomagok, letöltés, ellenőrzés
# ==================================================================

preflight() {
    [[ $EUID -eq 0 ]] && die "Ne rootként futtasd, hanem sudo joggal rendelkező userként."
    [[ "$(uname -m)" == "x86_64" ]] || warn "Nem x86_64 host – az aml-flash-tool 'update' binárisa x86_64-es."
    sudo -v || die "sudo jogosultság szükséges."
}

install_packages() {
    log "Csomagok frissítése és telepítése..."
    sudo apt-get update
    sudo apt-get -y upgrade
    # libusb-0.1-4: az aml 'update' bináris egyetlen valódi függősége
    # usbutils: lsusb a burn mode detektálásához
    sudo apt-get install -y git wget curl jq adb fastboot usbutils \
        python3-venv libusb-0.1-4 libusb-1.0-0 pv
}

setup_verifier() {
    if [[ ! -d "$VERIFIER_DIR" ]]; then
        log "update_verifier klónozása..."
        git clone --depth 1 "$VERIFIER_REPO" "$VERIFIER_DIR"
    fi
    if [[ ! -x "${VERIFIER_DIR}/.venv/bin/python" ]]; then
        python3 -m venv "${VERIFIER_DIR}/.venv"
        "${VERIFIER_DIR}/.venv/bin/pip" install -q -r "${VERIFIER_DIR}/requirements.txt"
    fi
}

verify_zip_signature() {
    local zip="$1"
    log "Aláírás ellenőrzése: $(basename "$zip")"
    "${VERIFIER_DIR}/.venv/bin/python" "${VERIFIER_DIR}/update_verifier.py" \
        "${VERIFIER_DIR}/lineageos_pubkey" "$zip" \
        || die "Aláírás HIBÁS: $(basename "$zip") – ne flasheld!"
    log "Aláírás OK: $(basename "$zip")"
}

setup_aml_tool() {
    if [[ ! -d "$AML_DIR" ]]; then
        log "aml-flash-tool klónozása..."
        git clone --depth 1 "$AML_REPO" "$AML_DIR"
    fi

    log "udev szabály telepítése (Amlogic burn mode)..."
    sudo tee /etc/udev/rules.d/70-persistent-usb-amlogic.rules >/dev/null <<EOF
SUBSYSTEMS=="usb", ATTRS{idVendor}=="1b8e", ATTRS{idProduct}=="c003", OWNER="${USER}", MODE="0666", SYMLINK+="worldcup"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="1b8e", ATTRS{idProduct}=="c004", OWNER="${USER}", MODE="0666", SYMLINK+="worldcup"
EOF
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    sudo ln -sf "${AML_DIR}/aml-flash-tool.sh" /usr/local/bin/aml-flash-tool.sh

    # Kozmetikai javítás: az újabb gawk (Ubuntu 24.04) figyelmeztet a
    # regexben lévő \" miatt. A működés helyes, csak zajos a kimenet.
    sed -i '/_type=\\"/s|\\"|"|g' "${AML_DIR}/aml-flash-tool.sh"

    if ldd "${AML_DIR}/tools/linux-x86/update" | grep -q 'not found'; then
        ldd "${AML_DIR}/tools/linux-x86/update"
        die "Az aml 'update' binárisnak hiányzó függősége van (lásd fent)."
    fi
    log "aml-flash-tool kész."
}

download_device() {
    local codename="$1"
    local dir="${PROJECT_DIR}/${DEVICES[$codename]}"
    local json build date

    log "[$codename] Legfrissebb build lekérdezése..."
    json=$(curl -fsSL "${API}/${codename}/builds") \
        || die "[$codename] Az API nem érhető el: ${API}/${codename}/builds"
    build=$(jq -c 'sort_by(.datetime) | last' <<<"$json")
    [[ -n "$build" && "$build" != "null" ]] || die "[$codename] Nincs elérhető build."

    date=$(jq -r '.date' <<<"$build")
    dir="${dir}/${date}"
    mkdir -p "$dir"
    cd "$dir"
    log "[$codename] Build: $(jq -r '.version' <<<"$build") / ${date} -> ${dir}"

    : > SHA256SUMS
    local name url sha
    while IFS=$'\t' read -r name url sha; do
        printf '%s  %s\n' "$sha" "$name" >> SHA256SUMS
        if [[ -f "$name" ]] && printf '%s  %s\n' "$sha" "$name" | sha256sum -c --status; then
            log "[$codename] $name már megvan, hash OK – kihagyva"
            continue
        fi
        log "[$codename] Letöltés: $name"
        wget -q --show-progress -O "${name}.part" "$url"
        if printf '%s  %s\n' "$sha" "${name}.part" | sha256sum -c --status; then
            mv "${name}.part" "$name"
            log "[$codename] $name SHA256 OK"
        else
            rm -f "${name}.part"
            die "[$codename] $name SHA256 ELTÉRÉS! Sérült vagy módosított fájl."
        fi
    done < <(jq -r '.files[] | [.filename, .url, .sha256] | @tsv' <<<"$build")

    local zip
    for zip in ./*-signed.zip; do
        [[ -e "$zip" ]] || { warn "[$codename] Nem találtam -signed.zip fájlt."; break; }
        verify_zip_signature "$zip"
    done

    # MindTheGapps letöltése a buildhez illő Android verzióhoz
    if (( NO_GAPPS )); then
        log "[$codename] MindTheGapps letöltés kihagyva (--no-gapps)."
    else
        local repo
        if repo=$(gapps_repo "$(jq -r '.version' <<<"$build")" "$codename"); then
            download_gapps "$repo" || warn "[$codename] MindTheGapps letöltése sikertelen – a flash-nél kézzel is megadható."
        else
            warn "[$codename] Ismeretlen LineageOS verzió a GApps-hoz, kihagyva."
        fi
    fi
}

# ==================================================================
#  MindTheGapps
# ==================================================================
# gapps_repo <LineageOS verzió, pl. 22.2> <eszköz>  ->  pl. 15.0.0-arm-ATV
gapps_repo() {
    local major="${1%%.*}" av
    av="${LOS_TO_ANDROID[$major]:-}"
    [[ -n "$av" && -n "${GAPPS_VARIANT[$2]:-}" ]] || return 1
    echo "${av}-${GAPPS_VARIANT[$2]}"
}

# A GitHub API helyett a release oldalt olvassa (nincs API rate limit).
download_gapps() {
    local repo="$1"
    local dir="${ADDON_DIR}/MindTheGapps-${repo}"
    local base="https://github.com/MindTheGapps/${repo}"
    local latest tag page url name expected

    mkdir -p "$dir" "$EXTRA_ADDON_DIR"
    log "MindTheGapps ${repo}: legfrissebb kiadás keresése..."
    latest=$(curl -fs -o /dev/null -w '%{redirect_url}' "${base}/releases/latest") || return 1
    tag="${latest##*/tag/}"
    [[ -n "$tag" && "$tag" != "$latest" ]] || return 1
    page=$(curl -fsSL "${base}/releases/expanded_assets/${tag}") || return 1

    local found=0
    while read -r url; do
        found=1
        name="${url##*/}"
        url="https://github.com${url}"
        curl -fsSL -o "${dir}/${name}.sha256sum" "${url}.sha256sum" || return 1
        expected=$(awk '{print $1; exit}' "${dir}/${name}.sha256sum")
        [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { warn "Érvénytelen sha256sum: ${name}"; return 1; }

        if [[ -f "${dir}/${name}" ]] && printf '%s  %s\n' "$expected" "${dir}/${name}" | sha256sum -c --status; then
            log "MindTheGapps: ${name} már megvan, hash OK – kihagyva"
            continue
        fi
        log "Letöltés: ${name}"
        wget -q --show-progress -O "${dir}/${name}.part" "$url" || return 1
        if printf '%s  %s\n' "$expected" "${dir}/${name}.part" | sha256sum -c --status; then
            mv "${dir}/${name}.part" "${dir}/${name}"
            log "MindTheGapps: ${name} SHA256 OK"
        else
            rm -f "${dir}/${name}.part"
            warn "MindTheGapps: ${name} SHA256 ELTÉRÉS – törölve."
            return 1
        fi
    done < <(grep -oE "/MindTheGapps/${repo}/releases/download/[^\"]+\.zip\"" <<<"$page" | tr -d '"' | sort -u)

    (( found )) || { warn "Nem találtam zip fájlt a(z) ${tag} kiadásban."; return 1; }
}

# ==================================================================
#  Eszköznév értelmezése (kis/nagybetű, szóköz, álnevek)
# ==================================================================
normalize_device() {
    local raw="$1" d
    d=$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$d" in
        odroidc4_tab|odroidc4-tab|odroid_c4_tab|odroid-c4-tab|c4_tab|c4-tab|c4tab)
            echo odroidc4_tab ;;
        m5_tab|m5-tab|m5tab|banana_m5_tab|bananapi_m5_tab|bpi-m5-tab|bpim5tab)
            echo m5_tab ;;
        odroidc4|odroid_c4|odroid-c4|c4|odroidc4_tv|odroidc4-tv|c4_tv|c4-tv)
            echo odroidc4 ;;
        m5|bananapim5|bananapi_m5|banana_m5|bpi-m5|bpim5|m5_tv|m5-tv)
            echo m5 ;;
        all|tab|tv) echo "$d" ;;
        *)   die "Ismeretlen eszköz: $(printf '%q' "$raw")  (érvényes: odroidc4_tab | m5_tab | odroidc4 | m5)" ;;
    esac
}

cmd_prep() {
    local dev targets=() positional=() a
    for a in "$@"; do
        case "$a" in
            --no-gapps) NO_GAPPS=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          positional+=("$a") ;;
        esac
    done
    [[ ${#positional[@]} -ge 1 ]] || die "Add meg, mit töltsön le (pl. odroidc4_tab, m5_tab, tab, tv, all). Súgó: --help"
    dev=$(normalize_device "${positional[0]}")
    case "$dev" in
        tab) targets=(odroidc4_tab m5_tab) ;;
        tv)  targets=(odroidc4 m5) ;;
        all) targets=(odroidc4_tab m5_tab odroidc4 m5) ;;
        *)   targets=("$dev") ;;
    esac
    preflight
    mkdir -p "$PROJECT_DIR"
    install_packages
    setup_verifier
    setup_aml_tool
    local d
    for d in "${targets[@]}"; do download_device "$d"; done
    log "Előkészítés kész."
    log "Következő: ./$(basename "$0") burn <eszköz>   (bootloader + partíciók)"
}

# ==================================================================
#  Közös segédek a burn / flash részhez
# ==================================================================
DEV=""; BUILD_DIR=""; ZIP=""; SHORT_MODE=0

find_latest_build() {
    local base="${PROJECT_DIR}/${DEVICES[$DEV]}"
    BUILD_DIR=$(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)
    [[ -n "$BUILD_DIR" ]] || die "Nincs letöltött build: $base – előbb: prep $DEV"
    ZIP=$(find "$BUILD_DIR" -maxdepth 1 -name '*-signed.zip' | head -n1)
}

need_file() {
    [[ -f "${BUILD_DIR}/$1" ]] || die "Hiányzik: ${BUILD_DIR}/$1 – futtasd újra: prep $DEV"
}

check_hashes() {
    log "Build: $BUILD_DIR"
    log "Fájlok újraellenőrzése (SHA256)..."
    ( cd "$BUILD_DIR" && sha256sum -c --quiet SHA256SUMS ) || die "Hash hiba – töltsd le újra (prep)."
    log "Hash OK."
}

confirm_wipe() {
    local what="$1" ans
    echo
    echo "${RED}FIGYELEM: ${what}${RST}"
    read -rp "Ha érted és folytatnád, írd be: IGEN  > " ans
    [[ "$ans" == "IGEN" ]] || die "Megszakítva."
}

# run_steps <függvénytömb neve> <névtömb neve> <kezdő lépés> <parancs>
run_steps() {
    local -n funcs="$1" names="$2"
    local start="$3" cmd="$4" i
    [[ "$start" =~ ^[0-9]+$ ]] && (( start < ${#funcs[@]} )) \
        || die "Érvénytelen lépés: $start (lásd: ./$(basename "$0") steps)"
    (( start > 0 )) && warn "Folytatás a(z) ${start}. lépéstől: ${names[$start]}"
    for (( i = start; i < ${#funcs[@]}; i++ )); do
        CUR_CMD="$cmd"; CUR_STEP="$i"
        echo
        echo "${GRN}════ ${cmd^^} ${i}. lépés: ${names[$i]} ════${RST}"
        "${funcs[$i]}"
    done
}

# hiba esetén megmondja, honnan lehet folytatni
resume_hint() { echo "Folytatás javítás után: ./$(basename "$0") ${CUR_CMD} ${DEV} ${1:-$CUR_STEP}"; }

# ==================================================================
#  BURN: aml-flash-tool (bootloader, partíciók, recovery)
# ==================================================================
BURN_NAMES=(
    "Ellenőrzés és megerősítés"
    "Burn mode (eszköz áramtalanítása és újraindítása)"
    "aml_install_package.img írása (aml-flash-tool)"
)
# shellcheck disable=SC2034  # run_steps névreferenciával használja
BURN_FUNCS=(burn_check burn_mode burn_aml)

burn_check() {
    need_file aml_install_package.img
    check_hashes
    echo "  - A firmware eMMC modult igényel, csak SD kártyával nem működik."
    if [[ "$DEV" == m5* ]]; then
        echo "  - Banana Pi M5: csatlakoztasd a Wi-Fi/BT perifériát"
        echo "    (hivatalos Wi-Fi/BT HAT vagy rtl8822cs USB dongle)."
    else
        echo "  - Odroid C4: burn mode csak akkor jön létre, ha az eMMC-n nincs"
        echo "    érvényes bootloader (üres modul, vagy rövidzár: --short)."
    fi
    confirm_wipe "az eszköz eMMC-je TELJESEN TÖRLŐDNI fog (bootloader, partíciók, adatok)!"
}

burn_mode() {
    if (( SHORT_MODE )); then
        reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – BURN MODE RÖVIDZÁRRAL" \
            "Húzd ki a tápot, kösd össze az eszközt USB-vel a PC-vel." \
            "Zárd az eMMC CMD vagy DAT0 vonalát GND-re." \
            "A zárat tartva dugd vissza a tápot." \
            "Tartsd a zárat, amíg a script jelzi, hogy megvan az eszköz."
    elif [[ "$DEV" == m5* ]]; then
        reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – BURN MODE (Banana Pi M5)" \
            "Húzd ki a tápot a Banana Pi-ből." \
            "Kösd össze USB kábellel a PC-vel." \
            "Tartsd NYOMVA az SW4 gombot, és közben dugd vissza a tápot." \
            "Addig tartsd nyomva, amíg logó meg nem jelenik a kijelzőn."
    else
        reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – BURN MODE (Odroid C4)" \
            "Húzd ki a tápot az Odroid-ból." \
            "Legyen rajta az ÜRES eMMC modul." \
            "Kösd össze a Micro-USB portot a PC-vel." \
            "Dugd vissza a tápot."
    fi
    wait_for "Amlogic eszköz (burn mode, USB 1b8e)" is_amlogic_burn

    if (( SHORT_MODE )); then
        printf '\a'
        echo "${RED}   ➜ MOST ENGEDD EL A RÖVIDZÁRAT!${RST} (az írás már működő eMMC-t igényel)"
        read -rp "   Ha elengedted, nyomj Entert... " _
    fi
}

burn_aml() {
    while true; do
        log "Írás: aml_install_package.img (ez eltarthat pár percig)"
        if sudo "${AML_DIR}/aml-flash-tool.sh" "${BUILD_DIR}/aml_install_package.img"; then
            log "Burn sikeres (bootloader és partíciók a helyén)."
            log "Következő: ./$(basename "$0") flash ${DEV}"
            return 0
        fi
        warn "Az aml-flash-tool hibával állt le. (AMD hoston ez ismert, gyakran újrapróbálva megy.)"
        ask_yes "Újrapróbálod? (előtte újra burn mode kell)" || die "Megszakítva. $(resume_hint)"
        burn_mode
    done
}

# ==================================================================
#  FLASH: LineageOS a recovery-n keresztül (bootloader már a helyén)
# ==================================================================
FLASH_NAMES=(
    "Ellenőrzés és megerősítés"
    "Eszköz indítása bootloader fastboot módba"
    "Helyes LineageOS recovery írása"
    "Recovery indítása, majd fastbootd"
    "super partíció előkészítése (wipe-super)"
    "Vissza recovery-be + Factory reset"
    "LineageOS zip sideload"
    "Add-onok (pl. MindTheGapps) – opcionális"
    "Első rendszerindítás"
)
# shellcheck disable=SC2034  # run_steps névreferenciával használja
FLASH_FUNCS=(flash_check flash_to_bootloader flash_recovery flash_to_fastbootd \
             flash_wipe_super flash_factory_reset flash_sideload flash_addons flash_first_boot)

flash_check() {
    need_file super_empty.img
    need_file recovery.img
    [[ -n "$ZIP" ]] || die "Nincs -signed.zip itt: $BUILD_DIR"
    check_hashes
    verify_zip_signature "$ZIP"
    echo "  - Előfeltétel: a bootloader már az eMMC-n van"
    echo "    (friss 'burn' után, vagy meglévő LineageOS telepítésen)."
    echo "  - A recovery-t a script a letöltött buildből újraírja."
    echo "  - Kell egy USB billentyűzet a recovery kezeléséhez."
    confirm_wipe "a rendszer és a felhasználói ADATOK törlődni fognak!"
}

# A recovery írásához a bootloader (u-boot) fastbootja kell, nem a fastbootd.
flash_to_bootloader() {
    if is_bl_fastboot; then
        log "Az eszköz már bootloader fastboot módban van."
        return 0
    fi
    if is_fastbootd; then
        reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – BOOTLOADER" \
            "Az eszköz fastbootd-ben van (recovery), a script átindítja bootloaderbe." \
            "Ne áramtalanítsd közben!"
        fastboot reboot bootloader
    elif is_adb_android && ask_yes "Futó Android eszközt látok adb-n. Újraindítsam bootloaderbe (adb reboot bootloader)?"; then
        reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – BOOTLOADER" \
            "A script most újraindítja az eszközt bootloader fastboot módba." \
            "Ne áramtalanítsd közben!"
        adb reboot bootloader
    else
        reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – POWER CYCLE" \
            "Friss burn után: áramtalanítsd, majd kapcsold vissza az eszközt." \
            "A Micro-USB (C4) / USB-OTG (M5) kábel maradjon a PC-n." \
            "A képernyőn a logó marad – ez normális, a bootloader fastbootban vár." \
            "(Rövidzárral burnolt C4-nél a zárat már NEM kell alkalmazni.)"
    fi
    wait_for "bootloader fastboot" is_bl_fastboot
}

flash_recovery() {
    is_bl_fastboot || die "Az eszköz nincs bootloader fastboot módban. $(resume_hint 1)"
    log "Recovery írása: ${BUILD_DIR}/recovery.img"
    fastboot flash recovery "${BUILD_DIR}/recovery.img" \
        || die "Recovery írása sikertelen. $(resume_hint)"
    log "Recovery OK."
}

flash_to_fastbootd() {
    if is_fastbootd; then
        log "Az eszköz már fastbootd módban van."
        return 0
    fi
    reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – RECOVERY" \
        "Csatlakoztass USB billentyűzetet az eszközhöz." \
        "A script most újraindítja az eszközt a friss recovery-be." \
        "Ne áramtalanítsd közben!"
    fastboot reboot recovery || warn "A fastboot reboot recovery hibát adott."
    todo "Várd meg, amíg a LineageOS Recovery menü betölt." \
         "(A '/cache' mount hibák az alján normálisak, a factory reset rendezi.)" \
         "A recovery-ben nyilakkal: 'Advanced' → Enter" \
         "Majd: 'Enter fastboot' → Enter"
    wait_for "fastbootd (recovery)" is_fastbootd
}

flash_wipe_super() {
    log "super partíció előkészítése + userdata törlés..."
    fastboot -w wipe-super "${BUILD_DIR}/super_empty.img" \
        || die "wipe-super sikertelen. $(resume_hint)"
    log "wipe-super OK."
}

flash_factory_reset() {
    if is_fastboot && ask_yes "Újraindítsam az eszközt recovery-be (fastboot reboot recovery)?"; then
        reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – RECOVERY" \
            "A script most újraindítja az eszközt recovery-be." \
            "Ne áramtalanítsd közben!"
        fastboot reboot recovery || warn "A fastboot reboot recovery hibát adott – próbáld a menüből."
        todo "Várd meg, amíg a LineageOS Recovery menü betölt a képernyőn."
    else
        reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – VISSZA RECOVERY-BE" \
            "A fastboot menüben nyilakkal: 'Enter Recovery' → Enter" \
            "Várd meg, amíg a recovery menü betölt."
    fi
    todo "Recovery: 'Factory Reset' → 'Format data / factory reset'" \
         "Erősítsd meg, és várd meg a végét." \
         "Utána lépj vissza a főmenübe."
}

flash_sideload() {
    todo "Recovery: 'Apply update' → 'Apply from ADB'"
    wait_for "adb sideload mód" is_sideload
    log "Sideload: $(basename "$ZIP")"
    if ! adb -d sideload "$ZIP"; then
        warn "Az adb nem 0-val lépett ki. Ez ismert jelenség:"
        warn "'failed to read command: Success / No error' (akár 47%-nál) még sikeres telepítés lehet."
        ask_yes "Az eszköz képernyője SIKERES telepítést mutat?" \
            || die "Sideload sikertelen. $(resume_hint)"
    fi
    log "LineageOS telepítve."
    echo "${YEL}   NE indítsd még el a rendszert, ha add-ont (pl. GApps) is szeretnél!${RST}"
}

# A buildből kiolvassa a LineageOS verziót (lineage-22.2-... -> 22.2)
los_version_from_zip() {
    basename "$ZIP" | sed -n 's/^lineage-\([0-9.]*\)-.*/\1/p'
}

sideload_addon() {
    local path="$1"
    todo "Recovery: 'Apply update' → 'Apply from ADB'" \
         "Ha 'Signature verification failed' jön: válaszd a 'Yes'-t" \
         "(az add-onok nincsenek LineageOS kulccsal aláírva – ez normális)."
    wait_for "adb sideload mód" is_sideload
    log "Sideload: $(basename "$path")"
    adb -d sideload "$path" \
        || ask_yes "Nem 0 kilépési kód – az eszköz sikert mutat?" \
        || die "Add-on telepítés sikertelen: $(basename "$path"). $(resume_hint)"
    log "Telepítve: $(basename "$path")"
}

flash_addons() {
    local -a files=() labels=() kinds=()
    local repo f v

    # 1) MindTheGapps (prep által letöltve)
    if repo=$(gapps_repo "$(los_version_from_zip)" "$DEV"); then
        local gdir="${ADDON_DIR}/MindTheGapps-${repo}"
        if [[ "$repo" == *-ATV ]]; then
            # Android TV: full / minimal változat
            for v in full minimal; do
                f=$(find "$gdir" -maxdepth 1 -name "MindTheGapps-*-${v}-*.zip" 2>/dev/null | sort | tail -n1)
                [[ -n "$f" ]] || continue
                files+=("$f"); kinds+=(gapps)
                if [[ "$v" == full ]]; then
                    labels+=("MindTheGapps FULL    – Google Android TV launcher + ajánlások  ($(basename "$f"))")
                else
                    labels+=("MindTheGapps MINIMAL – marad a LineageOS launcher               ($(basename "$f"))")
                fi
            done
        else
            # Tablet: egyetlen csomag, a legfrissebb
            f=$(find "$gdir" -maxdepth 1 -name "MindTheGapps-${repo}-*.zip" 2>/dev/null | sort | tail -n1)
            if [[ -n "$f" ]]; then
                files+=("$f"); kinds+=(gapps)
                labels+=("MindTheGapps – Google Play + szolgáltatások  ($(basename "$f"))")
            fi
        fi
    fi
    # 2) saját add-onok
    while IFS= read -r f; do
        files+=("$f"); kinds+=(extra); labels+=("Saját: $(basename "$f")")
    done < <(find "$EXTRA_ADDON_DIR" -maxdepth 1 -name '*.zip' 2>/dev/null | sort)

    echo
    echo "   Az add-onokat az ELSŐ rendszerindítás ELŐTT kell telepíteni."
    echo "   Elérhető add-onok:"
    local i
    if (( ${#files[@]} == 0 )); then
        echo "     (nincs letöltött add-on – 'prep' vagy tegyél zip-et ide: ${EXTRA_ADDON_DIR})"
    fi
    for i in "${!files[@]}"; do printf '     %d) %s\n' "$((i+1))" "${labels[$i]}"; done
    echo "     p) egyéni zip elérési út megadása"
    echo "     üres Enter = nincs add-on"

    local sel tok chosen=() gapps_count
    while true; do
        read -rp "   Választás (több is, szóközzel, pl. '2 3'): " sel
        chosen=(); gapps_count=0
        local ok=1
        for tok in $sel; do
            if [[ "$tok" == [pP] ]]; then
                local path
                read -rep "   Zip elérési útja: " path
                path="${path/#\~/$HOME}"
                if [[ -f "$path" ]]; then chosen+=("$path"); else warn "Nem létezik: $path"; ok=0; fi
            elif [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#files[@]} )); then
                chosen+=("${files[$((tok-1))]}")
                [[ "${kinds[$((tok-1))]}" == gapps ]] && (( ++gapps_count ))
            else
                warn "Érvénytelen választás: $tok"; ok=0
            fi
        done
        if (( gapps_count > 1 )); then
            warn "A FULL és MINIMAL MindTheGapps közül csak egyet válassz."; ok=0
        fi
        (( ok )) && break
    done

    if (( ${#chosen[@]} == 0 )); then
        log "Nincs add-on kiválasztva."
        return 0
    fi
    echo "   Telepítési sorrend:"
    for f in "${chosen[@]}"; do echo "     - $(basename "$f")"; done
    ask_yes "   Mehet?" || { warn "Add-onok kihagyva."; return 0; }
    for f in "${chosen[@]}"; do sideload_addon "$f"; done
}

flash_first_boot() {
    reboot_alert "ESZKÖZ ÚJRAINDÍTÁSA – ELSŐ LINEAGEOS BOOT" \
        "Recovery: bal felső vissza nyíl → 'Reboot system now'." \
        "Az első indulás a szokásosnál tovább tarthat, ne áramtalanítsd!"
    log "Kész! Jó szórakozást a LineageOS-hez. 🎉"
}

# ==================================================================
#  burn / flash belépési pontok
# ==================================================================
# Argumentumok: <eszköz> [lépés] [--short]
parse_dev_args() {
    local positional=() a
    for a in "$@"; do
        case "$a" in
            -s|--short) SHORT_MODE=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          positional+=("$a") ;;
        esac
    done
    [[ ${#positional[@]} -ge 1 ]] || die "Add meg az eszközt (odroidc4_tab | m5_tab | odroidc4 | m5). Súgó: --help"
    DEV=$(normalize_device "${positional[0]}")
    [[ "$DEV" != all && "$DEV" != tab && "$DEV" != tv ]] \
        || die "A burn/flash egyszerre csak egy eszközre futtatható."
    log "Eszköz: ${DEVICE_DESC[$DEV]} (${DEV})"
    START_STEP="${positional[1]:-0}"
}

cmd_burn() {
    parse_dev_args "$@"
    preflight
    [[ -x "${AML_DIR}/aml-flash-tool.sh" ]] || die "Nincs aml-flash-tool – előbb: prep"
    command -v lsusb >/dev/null || die "lsusb hiányzik – előbb: prep"
    find_latest_build
    run_steps BURN_FUNCS BURN_NAMES "$START_STEP" burn
}

cmd_flash() {
    parse_dev_args "$@"
    (( SHORT_MODE )) && warn "A --short kapcsolónak csak a burn parancsnál van hatása."
    preflight
    command -v fastboot >/dev/null && command -v adb >/dev/null || die "adb/fastboot hiányzik – előbb: prep"
    [[ -x "${VERIFIER_DIR}/.venv/bin/python" ]] || die "Nincs update_verifier – előbb: prep"
    find_latest_build
    run_steps FLASH_FUNCS FLASH_NAMES "$START_STEP" flash
}

cmd_steps() {
    local i
    echo "BURN lépések:"
    for i in "${!BURN_NAMES[@]}"; do printf '  %d. %s\n' "$i" "${BURN_NAMES[$i]}"; done
    echo
    echo "FLASH lépések:"
    for i in "${!FLASH_NAMES[@]}"; do printf '  %d. %s\n' "$i" "${FLASH_NAMES[$i]}"; done
}

usage() {
    local me; me=$(basename "$0")
    cat <<USAGE
LineageOS telepítő – Odroid C4 és Banana Pi M5 (Tablet / Android TV)
Host: Ubuntu 24.04 LTS, x86_64, sudo joggal rendelkező (nem root) user

HASZNÁLAT
  ./${me} <parancs> [eszköz] [lépés] [kapcsolók]

PARANCSOK
  prep  <eszköz|tab|tv|all> Csomagok telepítése, aml-flash-tool és update_verifier
                            beállítása, a legfrissebb build letöltése SHA256 és
                            aláírás-ellenőrzéssel, valamint a hozzá illő
                            MindTheGapps letöltése (TV-hez full + minimal).
                            tab = mindkét tablet, tv = mindkét TV, all = mind a 4.

  burn  <eszköz> [lépés]    Bootloader, partíciótábla és recovery írása
                            aml-flash-tool-lal, USB burn mode-ban.
                            Az eMMC teljes tartalma törlődik.

  flash <eszköz> [lépés]    LineageOS telepítése: a helyes recovery.img írása
                            bootloader fastbootból, majd recovery-n keresztül
                            wipe-super, factory reset, sideload, add-onok.
                            Feltétel: bootloader már a helyén van – friss 'burn'
                            után, vagy meglévő telepítésen.

  steps                     A burn és flash lépéseinek listája.
  help, -h, --help          Ez a súgó.

ESZKÖZÖK
  odroidc4_tab              Odroid C4, Tablet        (álnevek: c4_tab, c4-tab, odroid_c4_tab)
  m5_tab                    Banana Pi M5, Tablet     (álnevek: m5-tab, banana_m5_tab, bpi-m5-tab)
  odroidc4                  Odroid C4, Android TV    (álnevek: c4, c4_tv, odroid_c4)
  m5                        Banana Pi M5, Android TV (álnevek: m5_tv, banana_m5, bpi-m5)

KAPCSOLÓK
  --no-gapps                (csak prep) MindTheGapps letöltésének kihagyása.
  -s, --short               (csak burn) Burn mode rövidzárral (eMMC CMD/DAT0 → GND).
                            A felismerés után megáll, és szól, hogy engedd el a zárat.

TIPIKUS MENET
  ./${me} prep tab                     # mindkét tablet build + GApps
  ./${me} burn odroidc4_tab            # első telepítés, üres eMMC
  ./${me} burn odroidc4_tab --short    # nem üres eMMC (rövidzár)
  ./${me} flash odroidc4_tab           # LineageOS telepítése
  ./${me} flash m5_tab                 # újratelepítés, ha a bootloader már jó

FOLYTATÁS HIBA UTÁN
  Minden lépés sorszámozott; hiba esetén a script kiírja, honnan folytasd, pl.:
  ./${me} flash m5_tab 4

FÁJLOK
  ${PROJECT_DIR}/<eszköz>/<dátum>/   letöltött build + SHA256SUMS
  ${ADDON_DIR}/MindTheGapps-*/       letöltött GApps (flash-nél választható)
  ${EXTRA_ADDON_DIR}/                saját add-on zip-ek (flash-nél választható)
USAGE
}

# ==================================================================
case "${1:-}" in
    prep)             shift; cmd_prep "$@" ;;
    burn)             shift; cmd_burn "$@" ;;
    flash)            shift; cmd_flash "$@" ;;
    steps)            cmd_steps ;;
    help|-h|--help)   usage ;;
    "")               usage; exit 1 ;;
    *)                warn "Ismeretlen parancs: $(printf '%q' "$1")"; echo; usage; exit 1 ;;
esac
