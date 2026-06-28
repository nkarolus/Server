#!/bin/bash

################################################################################
# Ubuntu Server Initial Setup Script
# - Deaktiviert Root Login
# - Erstellt neuen Benutzer mit Sudo-Rechten und GitHub SSH Keys
# - Installiert und konfiguriert Fail2ban
# - Installiert und konfiguriert UFW Firewall
# - Wartet auf apt-Prozesse
# - Zeigt Progress mit grünen Haken
################################################################################

set -euo pipefail

# Farben für UI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Symbole
CHECK="✓"
CROSS="✗"
ARROW="→"

# Globale Variablen
USERNAME="${1:-}" # Benutzername als erstes Argument
GITHUB_USERNAME="${2:-}" # GitHub Username als zweites Argument
HOSTNAME_NEW="${3:-}" # Hostname als drittes Argument

################################################################################
# Funktionen
################################################################################

# Banner anzeigen
show_banner() {
    clear 2>/dev/null || true
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     Ubuntu Server Initial Security Setup                   ║"
    echo "║     Root Disabling • SSH Setup • Firewall • Fail2ban       ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
}

# Success Message mit grünem Haken
success() {
    echo -e "${GREEN}${CHECK}${NC} $1"
}

# Error Message mit roten X
error() {
    echo -e "${RED}${CROSS}${NC} $1"
}

# Warning Message
warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

# Info Message
info() {
    echo -e "${BLUE}${ARROW}${NC} $1"
}

# Auf apt-Locks warten
wait_for_apt() {
    info "Warte auf verfügbare apt-Prozesse..."
    
    while fuser /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* >/dev/null 2>&1; do
        echo -ne "\r  ${YELLOW}Noch geblockt...${NC}"
        sleep 2
    done
    
    success "apt ist verfügbar"
}

# Benutzer-Input validieren
validate_inputs() {
    if [[ -z "$USERNAME" ]]; then
        echo -e "\n${BLUE}${ARROW}${NC} Benutzernamen eingeben (z.B. 'admin', 'deploy'):"
        read -p "  > " USERNAME
        
        if [[ -z "$USERNAME" ]]; then
            error "Benutzername ist erforderlich!"
            exit 1
        fi
        
        # Validiere Benutzernamen (nur alphanumeric und underscore)
        if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            error "Ungültiger Benutzername (nur Kleinbuchstaben, Zahlen, _, - erlaubt)"
            exit 1
        fi
    fi
    
    if [[ -z "$GITHUB_USERNAME" ]]; then
        echo -e "\n${BLUE}${ARROW}${NC} GitHub Username eingeben (z.B. 'octocat'):"
        read -p "  > " GITHUB_USERNAME
        
        if [[ -z "$GITHUB_USERNAME" ]]; then
            error "GitHub Username ist erforderlich!"
            exit 1
        fi
    fi
    
    if [[ -z "$HOSTNAME_NEW" ]]; then
        echo -e "\n${BLUE}${ARROW}${NC} Hostname eingeben (z.B. 'server1', 'web-prod'):"
        read -p "  > " HOSTNAME_NEW
        
        if [[ -z "$HOSTNAME_NEW" ]]; then
            error "Hostname ist erforderlich!"
            exit 1
        fi
        
        # Validiere Hostname (RFC 1123)
        if ! [[ "$HOSTNAME_NEW" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
            error "Ungültiger Hostname (nur Kleinbuchstaben, Zahlen und - erlaubt)"
            exit 1
        fi
    fi
    
    info "Benutzer: ${BLUE}${USERNAME}${NC} | GitHub: ${BLUE}${GITHUB_USERNAME}${NC} | Hostname: ${BLUE}${HOSTNAME_NEW}${NC}"
}

# Schritt mit Nummer und Status
step_start() {
    local step_num=$1
    local step_name=$2
    echo -e "\n${BLUE}[${step_num}]${NC} ${step_name}"
    echo "────────────────────────────────────────"
}

# Schritt abgeschlossen
step_complete() {
    echo ""
}

################################################################################
# MAIN SETUP WORKFLOW
################################################################################

main() {
    show_banner
    
    # Prüfe ob root
    if [[ $EUID -ne 0 ]]; then
        error "Dieses Skript muss als root ausgeführt werden!"
        exit 1
    fi
    
    # GitHub Username validieren
    validate_inputs
    
    # Schritt 1: System aktualisieren
    step_start "1" "System aktualisieren"
    wait_for_apt
    info "apt update und upgrade..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq > /dev/null 2>&1
    success "System aktualisiert"
    step_complete
    
    # Schritt 2: Hostname setzen
    step_start "2" "Hostname konfigurieren"
    info "Setze Hostname auf '${HOSTNAME_NEW}'..."
    hostnamectl set-hostname "${HOSTNAME_NEW}"
    
    # Aktualisiere /etc/hosts
    if grep -q "^127.0.1.1" /etc/hosts; then
        # Vorhandene 127.0.1.1-Zeile ersetzen
        sed -i "s/^127.0.1.1.*/127.0.1.1\t${HOSTNAME_NEW}/" /etc/hosts
    else
        # Keine vorhanden -> neue Zeile anhaengen
        echo -e "127.0.1.1\t${HOSTNAME_NEW}" >> /etc/hosts
    fi
    
    success "Hostname auf '${HOSTNAME_NEW}' gesetzt"
    step_complete
    
    # Schritt 3: Neuen Benutzer erstellen
    step_start "3" "Erstelle Benutzer '${USERNAME}'"
    if id "${USERNAME}" &>/dev/null; then
        warning "Benutzer ${USERNAME} existiert bereits"
    else
        info "Benutzer wird erstellt..."
        useradd -m -s /bin/bash "${USERNAME}"
        # Stelle sicher, dass Home-Verzeichnis korrekte Permissions hat
        chmod 755 "/home/${USERNAME}"
        success "Benutzer ${USERNAME} erstellt"
    fi
    step_complete
    
    # Schritt 4: SSH-Keys von GitHub abrufen
    step_start "4" "GitHub SSH-Keys abrufen"
    info "Lade SSH-Keys von github.com/${GITHUB_USERNAME}"
    
    SSH_DIR="/home/${USERNAME}/.ssh"
    mkdir -p "${SSH_DIR}"
    
    if curl -sf "https://github.com/${GITHUB_USERNAME}.keys" -o "${SSH_DIR}/authorized_keys"; then
        # Wichtig: chown VOR chmod für korrekte Permissions
        chown -R "${USERNAME}:${USERNAME}" "${SSH_DIR}"
        chmod 700 "${SSH_DIR}"
        chmod 600 "${SSH_DIR}/authorized_keys"
        
        # Verifiziere Permissions
        if [[ $(stat -c %a "${SSH_DIR}") == "700" ]] && [[ $(stat -c %a "${SSH_DIR}/authorized_keys") == "600" ]]; then
            success "SSH-Keys erfolgreich importiert"
        else
            error "SSH-Permissions nicht korrekt gesetzt!"
            exit 1
        fi
    else
        error "Fehler beim Abrufen der SSH-Keys"
        warning "Prüfe GitHub Username: ${GITHUB_USERNAME}"
        exit 1
    fi
    step_complete
    
    # Schritt 5: Sudo-Berechtigung für Benutzer
    step_start "5" "Sudo-Berechtigung für ${USERNAME}"
    SUDOERS_FILE="/etc/sudoers.d/${USERNAME}"
    if [[ -f "${SUDOERS_FILE}" ]]; then
        warning "Sudo-Berechtigung existiert bereits"
    else
        echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}"
        chmod 0440 "${SUDOERS_FILE}"
        # Validiere Syntax, sonst Datei wieder entfernen (sudo nicht zerstoeren)
        if visudo -cf "${SUDOERS_FILE}" > /dev/null 2>&1; then
            success "Sudo-Berechtigung gewährt"
        else
            rm -f "${SUDOERS_FILE}"
            error "sudoers-Syntax ungültig - Datei entfernt"
            exit 1
        fi
    fi
    step_complete
    
    # Schritt 6: SSH-Konfiguration
    step_start "6" "SSH-Server konfigurieren"
    info "Konfiguriere SSH-Server..."

    # Backup erstellen
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

    # WICHTIG: Bei SSH gilt "erster Wert gewinnt". Auf Ubuntu-Cloud-Images
    # wird /etc/ssh/sshd_config.d/*.conf weit oben included (z.B. cloud-init
    # mit PasswordAuthentication yes). Eine Drop-in-Datei mit Prefix '00-'
    # wird alphabetisch zuerst gelesen und gewinnt daher zuverlaessig.

    # Stelle sicher, dass die Include-Zeile vorhanden ist
    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi

    mkdir -p /etc/ssh/sshd_config.d

    cat > /etc/ssh/sshd_config.d/00-hardening.conf << 'SSH_CONFIG'
# Server Security Settings (von Setup-Skript)
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
StrictModes yes
X11Forwarding no
PrintMotd no
AuthorizedKeysFile .ssh/authorized_keys
SSH_CONFIG
    chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf

    # Validiere SSH-Config
    if sshd -t > /dev/null 2>&1; then
        systemctl restart ssh
        success "SSH konfiguriert und neu gestartet"
    else
        error "SSH-Konfiguration fehlerhaft!"
        info "Entferne Hardening-Drop-in und stelle Backup wieder her..."
        rm -f /etc/ssh/sshd_config.d/00-hardening.conf
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        systemctl restart ssh
        exit 1
    fi
    step_complete
    
    # Schritt 7: UFW Firewall
    step_start "7" "UFW Firewall konfigurieren"
    wait_for_apt
    info "Installiere UFW..."
    apt-get install -y ufw -qq > /dev/null 2>&1
    
    info "Konfiguriere Firewall-Regeln..."
    # WICHTIG: Erst Regeln setzen, DANN aktivieren (kein Aussperr-Fenster)
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw allow 22/tcp comment 'SSH' > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1

    success "UFW aktiviert mit SSH (22) erlaubt"
    step_complete
    
    # Schritt 8: Fail2ban
    step_start "8" "Fail2ban installieren und konfigurieren"
    wait_for_apt
    info "Installiere Fail2ban..."
    apt-get install -y fail2ban python3-systemd -qq > /dev/null 2>&1
    
    info "Erstelle Fail2ban-Konfiguration..."
    
    # Fail2ban Konfiguration
    # backend = systemd funktioniert auf Ubuntu 22.04 UND 24.04
    # (auf 24.04 existiert /var/log/auth.log standardmaessig nicht).
    # Ban-only Action, da kein Mailserver (MTA) konfiguriert ist.
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd
action = %(action_)s

[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 600
bantime = 3600
EOF
    
    systemctl restart fail2ban
    success "Fail2ban installiert und konfiguriert"
    step_complete
    
    # Schritt 9: Fail2ban Aktivierung
    step_start "9" "Fail2ban Aktivierung und Test"
    
    # Stelle sicher dass Fail2ban aktiv ist
    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban
    
    # Warte kurz bis Fail2ban lädt
    sleep 2
    
    # Überprüfe Status
    if fail2ban-client status sshd > /dev/null 2>&1; then
        success "Fail2ban lädt SSH-Filter"
    else
        warning "SSH-Filter wird noch geladen..."
    fi
    
    success "Fail2ban aktiviert und konfiguriert"
    step_complete
    
    # Schritt 10: Sicherheits-Überprüfungen
    step_start "10" "Sicherheits-Verifikation"
    
    # Root Login Check
    if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config; then
        success "Root-Login deaktiviert"
    else
        error "Root-Login Deaktivierung fehlgeschlagen"
    fi
    
    # SSH Keys Check
    if [ -f "${SSH_DIR}/authorized_keys" ] && [ -s "${SSH_DIR}/authorized_keys" ]; then
        success "SSH-Keys sind konfiguriert"
        
        # Überprüfe SSH-Permissions
        SSH_DIR_PERMS=$(stat -c %a "${SSH_DIR}")
        AUTH_KEYS_PERMS=$(stat -c %a "${SSH_DIR}/authorized_keys")
        SSH_DIR_OWNER=$(stat -c %U "${SSH_DIR}")
        
        if [[ "$SSH_DIR_PERMS" == "700" ]] && [[ "$AUTH_KEYS_PERMS" == "600" ]] && [[ "$SSH_DIR_OWNER" == "$USERNAME" ]]; then
            success "SSH-Permissions korrekt (.ssh: 700, authorized_keys: 600)"
        else
            warning "SSH-Permissions: .ssh=$SSH_DIR_PERMS, authorized_keys=$AUTH_KEYS_PERMS, owner=$SSH_DIR_OWNER"
        fi
    else
        error "SSH-Keys nicht gefunden"
    fi
    
    # Firewall Check
    if ufw status | grep -q "Status: active"; then
        success "Firewall ist aktiv"
    else
        error "Firewall ist nicht aktiv"
    fi
    
    # Fail2ban Check
    if systemctl is-active --quiet fail2ban; then
        success "Fail2ban ist aktiv"
        
        # Überprüfe Fail2ban SSH-Konfiguration
        if grep -q "maxretry = 5" /etc/fail2ban/jail.local; then
            success "Fail2ban SSH: 5 Versuche vor Sperrung"
        else
            warning "Fail2ban SSH maxretry Einstellung prüfen"
        fi
        
        if grep -q "bantime = 3600" /etc/fail2ban/jail.local; then
            success "Fail2ban Sperrzeit: 1 Stunde (3600s)"
        else
            warning "Fail2ban bantime Einstellung prüfen"
        fi
    else
        error "Fail2ban ist nicht aktiv"
    fi
    
    step_complete
    
    # Schritt 11: Summary
    step_start "11" "Setup abgeschlossen"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✓ Server-Setup erfolgreich abgeschlossen  ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} System aktualisiert"
    echo -e "  ${GREEN}✓${NC} Hostname auf '${HOSTNAME_NEW}' gesetzt"
    echo -e "  ${GREEN}✓${NC} Benutzer '${USERNAME}' erstellt"
    echo -e "  ${GREEN}✓${NC} GitHub SSH-Keys importiert"
    echo -e "  ${GREEN}✓${NC} Root-Login deaktiviert"
    echo -e "  ${GREEN}✓${NC} UFW Firewall konfiguriert"
    echo -e "  ${GREEN}✓${NC} Fail2ban installiert"
    echo ""
    echo -e "  ${BLUE}Wichtige Informationen:${NC}"
    echo -e "  • Hostname: ${BLUE}${HOSTNAME_NEW}${NC}"
    echo -e "  • Benutzer: ${BLUE}${USERNAME}${NC}"
    echo -e "  • SSH-Port: ${BLUE}22${NC}"
    echo -e "  • Login-Befehl: ${BLUE}ssh ${USERNAME}@${HOSTNAME_NEW}${NC} oder ${BLUE}ssh ${USERNAME}@<server-ip>${NC}"
    echo ""
    echo -e "  ${BLUE}Fail2ban Einstellungen:${NC}"
    echo -e "  • SSH Versuche: ${BLUE}5 Versuche${NC}"
    echo -e "  • Zeitfenster: ${BLUE}10 Minuten${NC}"
    echo -e "  • Sperrzeit: ${BLUE}1 Stunde${NC}"
    echo ""
    echo -e "  ${YELLOW}SSH-Config Backup:${NC} /etc/ssh/sshd_config.backup"
    echo ""
}

# Script ausführen
main "$@"
