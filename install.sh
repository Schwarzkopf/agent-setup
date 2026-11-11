#!/usr/bin/env bash
# evooming agent-setup für macOS und Ubuntu/Debian
#
# Aufruf:
#   curl -fsSL https://github.com/Schwarzkopf/agent-setup/releases/latest/download/install.sh | bash
#
# Optionen (nach "bash -s --" anhängen):
#   --role agent|workstation   Rolle ohne Rückfrage festlegen
#   --yes                      keine Rückfragen, Vorschläge übernehmen
#   --skip-hermes              Hermes nicht installieren
#   --dry-run                  nur anzeigen, was passieren würde
#
# Dieselben Schalter als Umgebungsvariablen: EVOOMING_ROLE, EVOOMING_YES=1,
# EVOOMING_SKIP_HERMES=1, EVOOMING_DRY_RUN=1
#
# Passwörter ohne Rückfrage (z. B. für --yes):
#   EVOOMING_RUSTDESK_PASSWORD, EVOOMING_SYNCTHING_PASSWORD, EVOOMING_SYNCTHING_USER
#
# Das Skript ist mehrfach ausführbar: Installiertes wird aktualisiert, Erledigtes übersprungen.

set -o pipefail

SETUP_VERSION="dev"

RUSTDESK_HOST="rustdesk.klaus-schwarzkopf.de"
# Exportierte Netzwerkeinstellungen (ID-Server, Relay-Server, öffentlicher Schlüssel)
RUSTDESK_CONFIG='==Qfi0TU1wmcQFmcpVUT4QXVsh3MERXaNNmaRdkerxmW4ZDTjVDSpVHSiFFNkVWbiojI5V2aiwiIiojIpBXYiwiI3ETMxIjOlRmLmB3brpnchdHajNXLzVXYstmLrNXZkR3c1JnI6ISehxWZyJCLiYTMxEjM6UGZuYGcvtmeyF2doN2ctMXdhx2aus2clRGdzVnciojI0N3boJye'

VAULT_DIR="$HOME/evooming-Brain"
HERMES_INSTALLER="https://hermes-agent.nousresearch.com/install.sh"
LOG_FILE="$HOME/evooming-setup.log"

ROLE="${EVOOMING_ROLE:-}"
YES="${EVOOMING_YES:-0}"
DRY="${EVOOMING_DRY_RUN:-0}"
SKIP_HERMES="${EVOOMING_SKIP_HERMES:-0}"

OS=""
ARCH=""
SUDO=""
TMP_DIR=""
RESULTS=()
NEXT_STEPS=()
RUSTDESK_ID=""
SYNCTHING_ID=""
RUSTDESK_PW=""
SYNCTHING_USER=""
SYNCTHING_PW=""

# ---------------------------------------------------------------- Ausgabe

if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi

step()  { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_OFF"; }
info()  { printf '    %s\n' "$*"; }
ok()    { RESULTS+=("ok|$1|$2");   printf '    %s✓ %s%s %s\n' "$C_OK" "$1" "$C_OFF" "$2"; }
warn()  { RESULTS+=("warn|$1|$2"); printf '    %s! %s%s %s\n' "$C_WARN" "$1" "$C_OFF" "$2"; }
fail()  { RESULTS+=("fail|$1|$2"); printf '    %s✗ %s%s %s\n' "$C_FAIL" "$1" "$C_OFF" "$2"; }
skip()  { RESULTS+=("skip|$1|$2"); printf '    %s– %s %s%s\n' "$C_DIM" "$1" "$2" "$C_OFF"; }
next_step() { NEXT_STEPS+=("$1"); }
die()   { printf '\n%sAbbruch:%s %s\n' "$C_FAIL" "$C_OFF" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- Eingaben

# Unter "curl | bash" ist stdin das Skript selbst. Eingaben kommen deshalb vom Terminal.
has_tty() { (: </dev/tty) 2>/dev/null; }

interactive() { [ "$YES" = 0 ] && [ "$DRY" = 0 ] && has_tty; }

# ask "Frage" "Vorschlag" -> $REPLY
ask() {
    REPLY="$2"
    interactive || return 0
    printf '%s [%s]: ' "$1" "$2" >/dev/tty
    IFS= read -r REPLY </dev/tty || REPLY=""
    [ -n "$REPLY" ] || REPLY="$2"
}

# confirm "Frage" j|n -> 0 bei Ja
confirm() {
    local def="$2" hint="[J/n]"
    [ "$def" = "n" ] && hint="[j/N]"
    if ! interactive; then [ "$def" = "j" ]; return; fi
    printf '%s %s: ' "$1" "$hint" >/dev/tty
    local a; IFS= read -r a </dev/tty || a=""
    [ -n "$a" ] || a="$def"
    case "$a" in j|J|ja|Ja|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

# ask_secret "Bezeichnung" MINDESTLÄNGE -> $REPLY (leer = übersprungen)
ask_secret() {
    REPLY=""
    interactive || return 0
    local a b
    while :; do
        printf '%s (mind. %s Zeichen, leer lassen = später selbst setzen): ' "$1" "$2" >/dev/tty
        IFS= read -rs a </dev/tty || a=""; printf '\n' >/dev/tty
        [ -z "$a" ] && return 0
        if [ "${#a}" -lt "$2" ]; then printf '    Zu kurz, bitte noch einmal.\n' >/dev/tty; continue; fi
        printf 'Noch einmal zur Bestätigung: ' >/dev/tty
        IFS= read -rs b </dev/tty || b=""; printf '\n' >/dev/tty
        if [ "$a" = "$b" ]; then REPLY="$a"; return 0; fi
        printf '    Die Eingaben sind verschieden, bitte noch einmal.\n' >/dev/tty
    done
}

# ---------------------------------------------------------------- Hilfen

run() {
    if [ "$DRY" = 1 ]; then printf '    %s[dry-run] %s%s\n' "$C_DIM" "$*" "$C_OFF"; return 0; fi
    "$@"
}

download() {
    if [ "$DRY" = 1 ]; then
        curl -fsSIL --retry 3 -o /dev/null "$1" || return 1
        printf '    %s[dry-run] Download %s%s\n' "$C_DIM" "$1" "$C_OFF"
        return 0
    fi
    curl -fsSL --retry 3 -o "$2" "$1" && chmod 644 "$2"
}

# gh_latest_asset owner/repo 'regex' 'vorlage' -> URL des passenden Assets aus dem neuesten Release
# Ohne Anmeldung erlaubt die GitHub-API 60 Abfragen pro Stunde und Netz. Ist sie erschöpft,
# kommt die Version aus der Weiterleitung von releases/latest und der Dateiname aus der Vorlage
# ({tag} = Release-Name, {ver} = ohne führendes v).
gh_latest_asset() {
    local url tag ver auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    url="$(curl -fsSL --retry 3 "${auth[@]}" "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | grep '"browser_download_url"' | cut -d'"' -f4 | grep -E "$2" | head -n 1)"
    if [ -z "$url" ] && [ -n "$3" ]; then
        tag="$(curl -fsSI --retry 3 -o /dev/null -w '%{redirect_url}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##')"
        if [ -n "$tag" ]; then
            ver="${tag#v}"
            url="https://github.com/$1/releases/download/$tag/$(printf '%s' "$3" | sed "s/{ver}/$ver/g; s/{tag}/$tag/g")"
        fi
    fi
    printf '%s\n' "$url"
}

# Versionsnummer aus einem Asset-Dateinamen, z. B. rustdesk-1.5.3-x86_64.deb -> 1.5.3
version_from_url() { basename "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1; }

deb_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }

apt_get() { run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

install_deb() { # install_deb Paketname URL
    local file="$TMP_DIR/$1.deb"
    download "$2" "$file" || return 1
    apt_get install -y "$file" && return 0
    # Bei Netzwerk-Aussetzern einmal mit frischen Paketlisten neu versuchen
    info "Neuer Versuch in 10 Sekunden ..."
    sleep 10
    apt_get update -qq
    apt_get install -y "$file"
}

brew_cask() { # brew_cask cask "App-Name"
    if brew list --cask "$1" >/dev/null 2>&1; then
        run brew upgrade --cask "$1" >/dev/null 2>&1 || true
        ok "$2" "ist aktuell"
    elif [ -d "/Applications/$2.app" ]; then
        ok "$2" "war schon installiert (Updates über die App selbst)"
    elif run brew install --cask "$1"; then
        ok "$2" "installiert"
    else
        fail "$2" "Installation mit Homebrew fehlgeschlagen"
    fi
}

# ---------------------------------------------------------------- Vorbereitung

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --role) ROLE="$2"; shift ;;
            --role=*) ROLE="${1#--role=}" ;;
            --yes|-y) YES=1 ;;
            --dry-run) DRY=1 ;;
            --skip-hermes) SKIP_HERMES=1 ;;
            -h|--help) sed -n '2,21p' "$0" 2>/dev/null || true; exit 0 ;;
            *) die "Unbekannte Option: $1" ;;
        esac
        shift
    done
}

detect_system() {
    case "$(uname -s)" in
        Darwin) OS="mac" ;;
        Linux)
            command -v apt-get >/dev/null 2>&1 || die "Dieses Skript unterstützt Ubuntu und Debian (apt). Für andere Linux-Systeme folge der Anleitung im Kurs."
            OS="linux" ;;
        *) die "Unbekanntes System $(uname -s). Für Windows gibt es install.ps1." ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) ARCH="x86_64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) die "Unbekannte Prozessor-Architektur $(uname -m)." ;;
    esac
    if [ "$(id -u)" = 0 ]; then
        die "Bitte nicht mit sudo oder als root starten. Das Skript fragt selbst nach deinem Passwort, wenn es nötig ist."
    fi
}

choose_role() {
    case "$ROLE" in
        agent|workstation) return ;;
        "") ;;
        *) die "Unbekannte Rolle '$ROLE'. Erlaubt: agent, workstation." ;;
    esac
    if ! interactive; then ROLE="agent"; return; fi
    printf '\nWelchen Rechner richtest du ein?\n' >/dev/tty
    printf '  1) Agent-Rechner  (läuft rund um die Uhr: Syncthing, RustDesk, Chrome, ChatGPT, Hermes)\n' >/dev/tty
    printf '  2) Workstation    (dein Arbeitsplatz: Obsidian, Syncthing, RustDesk)\n' >/dev/tty
    while :; do
        printf 'Auswahl [1]: ' >/dev/tty
        local a; IFS= read -r a </dev/tty || a=""
        case "${a:-1}" in
            1) ROLE="agent"; return ;;
            2) ROLE="workstation"; return ;;
        esac
    done
}

collect_inputs() {
    step "Ein paar Angaben vorab"
    info "Danach läuft die Installation ohne weitere Fragen durch (bis auf Hermes am Ende)."

    SYNCTHING_USER="${EVOOMING_SYNCTHING_USER:-}"
    SYNCTHING_PW="${EVOOMING_SYNCTHING_PASSWORD:-}"
    if [ -z "$SYNCTHING_PW" ] && ! syncthing_gui_has_user; then
        info "Syncthing-Oberfläche: Benutzername und Passwort (schützt die Oberfläche unter http://127.0.0.1:8384)."
        ask "Benutzername für Syncthing" "${SYNCTHING_USER:-$USER}"; SYNCTHING_USER="$REPLY"
        ask_secret "Passwort für Syncthing" 8; SYNCTHING_PW="$REPLY"
    fi
    [ -n "$SYNCTHING_USER" ] || SYNCTHING_USER="$USER"

    if [ "$ROLE" = "agent" ]; then
        RUSTDESK_PW="${EVOOMING_RUSTDESK_PASSWORD:-}"
        if [ -z "$RUSTDESK_PW" ] && rustdesk_permanent_set; then
            info ""
            info "RustDesk: Das dauerhafte Passwort ist schon eingerichtet."
        elif [ -z "$RUSTDESK_PW" ]; then
            info ""
            info "RustDesk: dauerhaftes Passwort für den Fernzugriff auf diesen Rechner."
            info "Wähle ein langes Passwort und speichere es gleich in deinem Passwort-Manager."
            ask_secret "Dauerhaftes RustDesk-Passwort" 12; RUSTDESK_PW="$REPLY"
        fi
    fi
}

acquire_sudo() {
    [ "$DRY" = 1 ] && return
    step "Administratorrechte"
    info "Für die Installation brauchst du einmal dein Passwort (das Passwort, mit dem du dich am Rechner anmeldest)."
    if has_tty; then sudo -v </dev/tty || die "Ohne Administratorrechte geht es nicht."
    else sudo -n true 2>/dev/null || die "Ohne Terminal kann ich nicht nach dem Passwort fragen."
    fi
    # sudo-Anmeldung während der Installation frisch halten
    ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
}

prepare() {
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/evooming-setup.XXXXXX")" || die "Kein temporärer Ordner möglich."
    chmod 755 "$TMP_DIR"
    trap 'rm -rf "$TMP_DIR"' EXIT

    SUDO="sudo"

    if [ "$OS" = "mac" ]; then ensure_brew; else apt_get update -qq || warn "Paketlisten" "apt-get update meldete einen Fehler"; fi
}

ensure_brew() {
    local b
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && eval "$("$b" shellenv)" && break
    done
    if command -v brew >/dev/null 2>&1; then ok "Homebrew" "vorhanden"; return; fi

    step "Homebrew installieren"
    info "Homebrew ist der Paketmanager für macOS. Darüber kommen die Programme immer in der neuesten Version."
    if [ "$DRY" = 1 ]; then run "Homebrew-Installer"; return; fi
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty \
        || die "Homebrew ließ sich nicht installieren."
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$b" ]; then
            eval "$("$b" shellenv)"
            grep -qs 'brew shellenv' "$HOME/.zprofile" || printf '\neval "$(%s shellenv)"\n' "$b" >> "$HOME/.zprofile"
            break
        fi
    done
    command -v brew >/dev/null 2>&1 || die "Homebrew ist installiert, aber nicht auffindbar."
    ok "Homebrew" "installiert"
}

# ---------------------------------------------------------------- Dauerbetrieb (Lektion 3.1)

setup_power() {
    step "Dauerbetrieb: kein Standby"
    if [ "$OS" = "mac" ]; then
        if run sudo pmset -a sleep 0 disksleep 0 displaysleep 15 autorestart 1 womp 1; then
            ok "Energie" "Ruhezustand aus, Bildschirm aus nach 15 min, Neustart nach Stromausfall"
        else
            fail "Energie" "pmset fehlgeschlagen, bitte von Hand einstellen (Lektion 3.1)"
        fi
        next_step "Automatische Anmeldung einschalten: Systemeinstellungen → Benutzer:innen & Gruppen (Lektion 3.1)."
        return
    fi

    if run sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1; then
        ok "Energie" "Standby und Ruhezustand abgeschaltet"
    else
        fail "Energie" "systemctl mask fehlgeschlagen, bitte von Hand einstellen (Lektion 3.1)"
    fi
    if command -v gsettings >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        run gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
        run gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
        run gsettings set org.gnome.desktop.session idle-delay 900 2>/dev/null || true
    fi

    setup_gdm
}

# Automatische Anmeldung und Xorg statt Wayland, damit RustDesk ohne Bestätigung funktioniert
setup_gdm() {
    local conf="/etc/gdm3/custom.conf"
    if [ ! -f "$conf" ]; then
        warn "Anmeldung" "kein GDM gefunden: automatische Anmeldung und Xorg bitte von Hand einstellen (Lektion 3.1)"
        return
    fi
    if grep -qE '^AutomaticLoginEnable=(true|True)' "$conf" && grep -qE '^WaylandEnable=false' "$conf"; then
        ok "Anmeldung" "automatische Anmeldung und Xorg sind schon eingestellt"
        return
    fi
    info "Für den Fernzugriff ohne Bestätigung braucht RustDesk Xorg statt Wayland,"
    info "und der agent braucht eine automatische Anmeldung nach jedem Neustart."
    if ! confirm "Automatische Anmeldung für $USER und Xorg einschalten?" j; then
        skip "Anmeldung" "übersprungen, bitte von Hand einstellen (Lektion 3.1)"
        return
    fi
    run sudo cp "$conf" "$conf.vor-evooming-setup"
    gdm_set "$conf" AutomaticLoginEnable true
    gdm_set "$conf" AutomaticLogin "$USER"
    gdm_set "$conf" WaylandEnable false
    ok "Anmeldung" "automatische Anmeldung und Xorg eingeschaltet (wirkt nach dem Neustart)"
    next_step "Agent-Rechner neu starten, damit automatische Anmeldung und Xorg greifen."
}

gdm_set() { # gdm_set Datei Schlüssel Wert
    if grep -qE "^[#[:space:]]*$2[[:space:]]*=" "$1"; then
        run sudo sed -i -E "s|^[#[:space:]]*$2[[:space:]]*=.*|$2=$3|" "$1"
    elif grep -q '^\[daemon\]' "$1"; then
        run sudo sed -i "/^\[daemon\]/a $2=$3" "$1"
    else
        printf '\n[daemon]\n%s=%s\n' "$2" "$3" | run sudo tee -a "$1" >/dev/null
    fi
}

# ---------------------------------------------------------------- Syncthing (Lektion 2.4 / 3.2)

syncthing_bin() {
    command -v syncthing 2>/dev/null && return
    [ -x /opt/homebrew/bin/syncthing ] && { echo /opt/homebrew/bin/syncthing; return; }
    [ -x /usr/local/bin/syncthing ] && echo /usr/local/bin/syncthing
}

syncthing_config_file() {
    local bin; bin="$(syncthing_bin)"; [ -n "$bin" ] || return 1
    "$bin" paths 2>/dev/null | grep -m1 'config\.xml' | tr -d '[:space:]'
}

syncthing_gui_has_user() {
    local f; f="$(syncthing_config_file)" || return 1
    [ -n "$f" ] && [ -f "$f" ] && grep -qE '<user>[^<]+</user>' "$f"
}

syncthing_service() { # start|stop
    if [ "$OS" = "mac" ]; then run brew services "$1" syncthing >/dev/null 2>&1
    else run sudo systemctl "$1" "syncthing@$USER"
    fi
}

setup_syncthing() {
    step "Syncthing"
    if [ "$OS" = "mac" ]; then
        if brew list syncthing >/dev/null 2>&1; then run brew upgrade syncthing >/dev/null 2>&1 || true
        else run brew install syncthing || { fail "Syncthing" "Installation fehlgeschlagen"; return; }
        fi
        run brew services start syncthing >/dev/null 2>&1 || true
    else
        local list="/etc/apt/sources.list.d/syncthing.list"
        if [ ! -f "$list" ]; then
            run sudo mkdir -p /etc/apt/keyrings
            run sudo curl -fsSL -o /etc/apt/keyrings/syncthing-archive-keyring.gpg https://syncthing.net/release-key.gpg
            echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable-v2" \
                | run sudo tee "$list" >/dev/null
            apt_get update -qq
        fi
        apt_get install -y syncthing || { sleep 10; apt_get update -qq; apt_get install -y syncthing; } \
            || { fail "Syncthing" "Installation fehlgeschlagen"; return; }
        run sudo systemctl enable --now "syncthing@$USER" >/dev/null 2>&1 \
            || { fail "Syncthing" "Dienst ließ sich nicht starten"; return; }
    fi
    ok "Syncthing" "installiert, startet automatisch"
    [ "$DRY" = 1 ] && return

    # Warten, bis der Dienst seine Konfiguration angelegt hat
    local i f=""
    for i in $(seq 1 30); do
        f="$(syncthing_config_file)"; [ -n "$f" ] && [ -f "$f" ] && break; sleep 1
    done

    local bin; bin="$(syncthing_bin)"
    if syncthing_gui_has_user; then
        ok "Syncthing-Oberfläche" "Benutzername und Passwort sind schon gesetzt"
    elif [ -n "$SYNCTHING_PW" ]; then
        syncthing_service stop
        if printf '%s\n' "$SYNCTHING_PW" | "$bin" generate --gui-user="$SYNCTHING_USER" --gui-password=- >/dev/null 2>&1; then
            ok "Syncthing-Oberfläche" "geschützt mit Benutzer '$SYNCTHING_USER'"
        else
            fail "Syncthing-Oberfläche" "Passwort ließ sich nicht setzen"
        fi
        syncthing_service start
    else
        warn "Syncthing-Oberfläche" "noch ohne Passwort"
        next_step "Syncthing-Passwort setzen: http://127.0.0.1:8384 → Aktionen → Einstellungen → GUI."
    fi

    SYNCTHING_ID="$("$bin" device-id 2>/dev/null || "$bin" --device-id 2>/dev/null)"
}

setup_vault_folder() {
    step "Vault-Ordner"
    if [ "$ROLE" = "agent" ]; then
        run mkdir -p "$VAULT_DIR"
    elif [ ! -d "$VAULT_DIR" ]; then
        warn "Vault" "$VAULT_DIR gibt es noch nicht"
        next_step "Vault-ZIP nach $VAULT_DIR entpacken (Lektion 2.1) und dieses Skript noch einmal starten, dann setzt es die Syncthing-Ignoriermuster."
        return
    fi
    # Obsidian-Fensterdateien nicht synchronisieren (Lektion 3.2, Schritt 5). .stignore bleibt lokal.
    local pattern added=0
    for pattern in ".obsidian/workspace.json" ".obsidian/workspace-mobile.json" ".trash"; do
        if ! grep -qxF "$pattern" "$VAULT_DIR/.stignore" 2>/dev/null; then
            [ "$DRY" = 1 ] || printf '%s\n' "$pattern" >> "$VAULT_DIR/.stignore"
            added=1
        fi
    done
    if [ "$added" = 1 ]; then ok "Vault" "$VAULT_DIR mit Syncthing-Ignoriermustern"
    else ok "Vault" "$VAULT_DIR, Ignoriermuster schon gesetzt"
    fi
}

# ---------------------------------------------------------------- RustDesk (Lektion 2.5 / 3.3)

rustdesk_bin() {
    if [ "$OS" = "mac" ]; then echo "/Applications/RustDesk.app/Contents/MacOS/RustDesk"; else echo "rustdesk"; fi
}

rustdesk_permanent_set() {
    [ "$DRY" = 1 ] && return 1
    local bin; bin="$(rustdesk_bin)"
    { [ -x "$bin" ] || command -v "$bin" >/dev/null 2>&1; } || return 1
    sudo -n "$bin" --option verification-method 2>/dev/null | grep -q use-permanent-password
}

rustdesk_configured() {
    sudo "$(rustdesk_bin)" --option custom-rendezvous-server 2>/dev/null | grep -q "$RUSTDESK_HOST"
}

setup_rustdesk() {
    step "RustDesk"
    if [ "$OS" = "mac" ]; then
        brew_cask rustdesk "RustDesk"
    else
        local re url latest current
        local rarch="x86_64"; [ "$ARCH" = "arm64" ] && rarch="aarch64"
        re="rustdesk-[0-9.]+-$rarch\.deb\$"
        url="$(gh_latest_asset rustdesk/rustdesk "$re" "rustdesk-{ver}-$rarch.deb")"
        [ -n "$url" ] || { fail "RustDesk" "neueste Version nicht gefunden (GitHub nicht erreichbar?)"; return; }
        latest="$(version_from_url "$url")"; current="$(deb_version rustdesk)"
        if [ "$current" = "$latest" ]; then
            ok "RustDesk" "ist aktuell ($latest)"
        elif install_deb rustdesk "$url"; then
            ok "RustDesk" "$latest installiert"
        else
            fail "RustDesk" "Installation fehlgeschlagen"; return
        fi
    fi
    [ "$DRY" = 1 ] && return

    if [ "$OS" = "mac" ]; then
        info "RustDesk braucht auf dem Mac zwei Rechte, die nur du erteilen kannst."
        info "Ich öffne RustDesk und die passenden Seiten der Systemeinstellungen:"
        info "  1. Datenschutz & Sicherheit → Bildschirmaufnahme: RustDesk einschalten"
        info "  2. Datenschutz & Sicherheit → Bedienungshilfen: RustDesk einschalten"
        info "  3. Fragt RustDesk nach deinem Passwort, um einen Dienst zu installieren: bestätigen"
        open -a RustDesk 2>/dev/null || true
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
        if interactive; then
            printf '    Drück Enter, wenn du fertig bist. ' >/dev/tty; read -r _ </dev/tty || true
        fi
    else
        sudo systemctl enable --now rustdesk >/dev/null 2>&1 || true
        sleep 3
    fi

    local bin; bin="$(rustdesk_bin)"
    if rustdesk_configured; then
        ok "RustDesk-Server" "$RUSTDESK_HOST ist schon eingetragen"
    else
        sudo "$bin" --config "$RUSTDESK_CONFIG" >/dev/null 2>&1
        sleep 2
        if rustdesk_configured; then
            ok "RustDesk-Server" "$RUSTDESK_HOST eingetragen"
        else
            warn "RustDesk-Server" "ließ sich nicht automatisch eintragen"
            if [ "$OS" = "mac" ]; then printf '%s' "$RUSTDESK_CONFIG" | pbcopy 2>/dev/null; fi
            next_step "RustDesk-Server von Hand eintragen (Lektion 2.5, Schritt 2). Der Text dafür steht in der Lektion$( [ "$OS" = "mac" ] && printf ' und liegt schon in deiner Zwischenablage')."
        fi
    fi

    if [ "$ROLE" = "agent" ]; then
        if [ -n "$RUSTDESK_PW" ]; then
            # Das Passwort nimmt nur der laufende RustDesk-Dienst an, der braucht nach der Installation ein paar Sekunden
            local pw_ok=0 _
            for _ in 1 2 3 4 5 6; do
                if sudo "$bin" --password "$RUSTDESK_PW" 2>/dev/null | grep -q "Done"; then pw_ok=1; break; fi
                sleep 3
            done
            if [ "$pw_ok" = 1 ]; then
                sudo "$bin" --option verification-method use-permanent-password >/dev/null 2>&1
                ok "RustDesk-Zugriff" "dauerhaftes Passwort gesetzt, nur dieses Passwort gilt"
            else
                if [ "$OS" = "linux" ]; then
                    fail "RustDesk-Zugriff" "Passwort ließ sich nicht setzen (RustDesk braucht eine angemeldete Bildschirmsitzung, nicht SSH)"
                else
                    fail "RustDesk-Zugriff" "Passwort ließ sich nicht setzen"
                fi
                next_step "RustDesk: dauerhaftes Passwort von Hand setzen (Lektion 3.3, Schritt 3) oder das Skript am Bildschirm des Agent-Rechners noch einmal starten."
            fi
        elif rustdesk_permanent_set; then
            ok "RustDesk-Zugriff" "dauerhaftes Passwort ist schon eingerichtet"
        else
            warn "RustDesk-Zugriff" "noch kein dauerhaftes Passwort"
            next_step "RustDesk: dauerhaftes Passwort setzen (Lektion 3.3, Schritt 3)."
        fi
        RUSTDESK_ID="$(sudo "$bin" --get-id 2>/dev/null | tr -d '[:space:]')"
        next_step "Von der Workstation aus mit RustDesk verbinden und den Agent-Rechner als Favorit speichern (Lektion 3.3, Schritt 4)."
    fi
}

# ---------------------------------------------------------------- Obsidian (Lektion 2.2)

setup_obsidian() {
    step "Obsidian"
    if [ "$OS" = "mac" ]; then brew_cask obsidian "Obsidian"; return; fi
    if [ "$ARCH" != "x86_64" ]; then
        skip "Obsidian" "für ARM-Linux gibt es kein .deb, bitte das AppImage von obsidian.md/download nehmen"
        return
    fi
    local url latest current
    url="$(gh_latest_asset obsidianmd/obsidian-releases 'obsidian_[0-9.]+_amd64\.deb$' 'obsidian_{ver}_amd64.deb')"
    [ -n "$url" ] || { fail "Obsidian" "neueste Version nicht gefunden (GitHub nicht erreichbar?)"; return; }
    latest="$(version_from_url "$url")"; current="$(deb_version obsidian)"
    if [ "$current" = "$latest" ]; then ok "Obsidian" "ist aktuell ($latest)"
    elif install_deb obsidian "$url"; then ok "Obsidian" "$latest installiert"
    else fail "Obsidian" "Installation fehlgeschlagen"
    fi
    # shellcheck disable=SC1111  # deutsche Anführungszeichen sind Absicht
    next_step "Obsidian öffnen → „Ordner als Vault öffnen“ → $VAULT_DIR (Lektion 2.2)."
}

# ---------------------------------------------------------------- Chrome und ChatGPT (Lektion 3.4)

setup_chrome() {
    step "Google Chrome"
    if [ "$OS" = "mac" ]; then brew_cask google-chrome "Google Chrome"; return; fi
    if [ "$ARCH" != "x86_64" ]; then skip "Google Chrome" "gibt es für ARM-Linux nicht"; return; fi
    if [ -n "$(deb_version google-chrome-stable)" ]; then
        if apt_get install -y --only-upgrade google-chrome-stable >/dev/null; then ok "Google Chrome" "ist aktuell"
        else warn "Google Chrome" "installiert, Update fehlgeschlagen"
        fi
    elif install_deb google-chrome "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; then
        ok "Google Chrome" "installiert"
    else
        fail "Google Chrome" "Installation fehlgeschlagen"
    fi
}

setup_chatgpt() {
    step "ChatGPT Desktop"
    if [ "$OS" = "mac" ]; then
        if [ "$ARCH" != "arm64" ]; then skip "ChatGPT Desktop" "gibt es nur für Macs mit Apple-Chip"; return; fi
        brew_cask chatgpt "ChatGPT"  # App-Name in /Applications
    else
        local deb="chatgpt_amd64.deb"; [ "$ARCH" = "arm64" ] && deb="chatgpt_arm64.deb"
        if install_deb chatgpt "https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/$deb"; then
            ok "ChatGPT Desktop" "installiert bzw. aktuell"
        else
            fail "ChatGPT Desktop" "Installation fehlgeschlagen"; return
        fi
    fi
    next_step "ChatGPT Desktop öffnen, mit deinem Abo anmelden und ein Projekt mit dem Ordner evooming-Brain anlegen (Lektion 3.4)."
}

# ---------------------------------------------------------------- Hermes (Lektion 3.5)

hermes_bin() {
    command -v hermes 2>/dev/null && return
    local p; for p in "$HOME/.local/bin/hermes" "$HOME/.hermes/bin/hermes"; do [ -x "$p" ] && { echo "$p"; return; }; done
}

setup_hermes() {
    step "Hermes (evooming agent)"
    if [ "$SKIP_HERMES" = 1 ]; then skip "Hermes" "übersprungen (--skip-hermes)"; return; fi
    local bin; bin="$(hermes_bin)"
    if [ -n "$bin" ]; then
        if run "$bin" update; then ok "Hermes" "aktualisiert"; else warn "Hermes" "installiert, Update fehlgeschlagen"; fi
        return
    fi
    info "Jetzt kommt der offizielle Hermes-Installer. Am Ende startet sein Einrichtungsassistent."
    info "Lass ihn durchlaufen, nimm die Vorschläge und lass leer, was du noch nicht hast."
    local file="$TMP_DIR/hermes-install.sh"
    download "$HERMES_INSTALLER" "$file" || { fail "Hermes" "Installer nicht erreichbar"; return; }
    if [ "$DRY" = 1 ]; then return; fi
    local rc
    if interactive; then bash "$file" </dev/tty; rc=$?
    else bash "$file" --non-interactive </dev/null; rc=$?
    fi
    if [ "$rc" = 0 ]; then
        ok "Hermes" "installiert"
        next_step "Neues Terminal öffnen, dann: hermes model → ChatGPT-Abo verbinden, hermes gateway setup → Telegram (Lektion 3.5)."
    else
        fail "Hermes" "Installer endete mit Fehler $rc"
    fi
}

# ---------------------------------------------------------------- Zusammenfassung

summary() {
    local r status name detail n_fail=0
    pad() { local t="$1"; while [ "${#t}" -lt 22 ]; do t="$t "; done; printf '%s' "$t"; }
    printf '\n%s=====================================================%s\n' "$C_BOLD" "$C_OFF"
    printf '%s evooming agent-setup %s – Ergebnis (%s)%s\n' "$C_BOLD" "$SETUP_VERSION" "$( [ "$ROLE" = agent ] && echo Agent-Rechner || echo Workstation )" "$C_OFF"
    printf '%s=====================================================%s\n' "$C_BOLD" "$C_OFF"
    for r in "${RESULTS[@]}"; do
        status="${r%%|*}"; r="${r#*|}"; name="${r%%|*}"; detail="${r#*|}"
        case "$status" in
            ok)   printf ' %s✓%s %s %s\n' "$C_OK" "$C_OFF" "$(pad "$name")" "$detail" ;;
            warn) printf ' %s!%s %s %s\n' "$C_WARN" "$C_OFF" "$(pad "$name")" "$detail" ;;
            fail) printf ' %s✗%s %s %s\n' "$C_FAIL" "$C_OFF" "$(pad "$name")" "$detail"; n_fail=$((n_fail + 1)) ;;
            skip) printf ' %s– %s %s%s\n' "$C_DIM" "$(pad "$name")" "$detail" "$C_OFF" ;;
        esac
    done
    if [ -n "$RUSTDESK_ID$SYNCTHING_ID" ]; then
        printf '\n%sDiese Angaben brauchst du gleich:%s\n' "$C_BOLD" "$C_OFF"
        [ -n "$RUSTDESK_ID" ] && printf '  RustDesk-ID:          %s\n' "$RUSTDESK_ID"
        [ -n "$SYNCTHING_ID" ] && printf '  Syncthing-Geräte-ID:  %s\n' "$SYNCTHING_ID"
    fi
    if [ "$ROLE" = "agent" ]; then
        next_step "Syncthing: Workstation hinzufügen und den Vault-Ordner annehmen, Pfad $VAULT_DIR (Lektion 3.2, Schritt 2 bis 4)."
    else
        next_step "Syncthing: Vault-Ordner teilen, sobald der Agent-Rechner eingerichtet ist (Lektion 3.2)."
    fi
    if [ "${#NEXT_STEPS[@]}" -gt 0 ]; then
        printf '\n%sNoch von Hand zu tun:%s\n' "$C_BOLD" "$C_OFF"
        local i=1 s
        for s in "${NEXT_STEPS[@]}"; do printf '  %d. %s\n' "$i" "$s"; i=$((i + 1)); done
    fi
    printf '\nProtokoll: %s\n' "$LOG_FILE"
    if [ "$n_fail" -gt 0 ]; then
        printf '%sEs gab %d Fehler.%s Du kannst das Skript einfach noch einmal starten.\n' "$C_FAIL" "$n_fail" "$C_OFF"
        printf 'Hilft das nicht, schick das Protokoll an den Support.\n'
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- Ablauf

main() {
    parse_args "$@"
    if [ "$DRY" = 0 ]; then exec > >(tee -a "$LOG_FILE") 2>&1; fi

    printf '\n%sevooming agent-setup %s%s  (%s)\n' "$C_BOLD" "$SETUP_VERSION" "$C_OFF" "$(date '+%Y-%m-%d %H:%M')"
    detect_system
    info "System: $OS ($ARCH)"
    [ "$DRY" = 1 ] && info "Probelauf: es wird nichts verändert."

    choose_role
    info "Rolle: $( [ "$ROLE" = agent ] && echo Agent-Rechner || echo Workstation )"
    acquire_sudo
    collect_inputs
    prepare

    if [ "$ROLE" = "agent" ]; then
        setup_power
        setup_syncthing
        setup_vault_folder
        setup_rustdesk
        setup_chrome
        setup_chatgpt
        setup_hermes
    else
        setup_obsidian
        setup_syncthing
        setup_vault_folder
        setup_rustdesk
    fi
    summary
}

main "$@"
