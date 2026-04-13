#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Headless RDP Setup für Ubuntu (ohne Monitor / HDMI)
# Komponenten: xrdp + xorgxrdp + Dummy-Videotreiber
# Getestet mit Ubuntu 22.04 / 24.04
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()  { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

# ─── Root-Check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Als root ausführen: sudo $0"

# ─── Desktop-Umgebung ermitteln ───────────────────────────────────────────────
detect_de() {
  if dpkg -l ubuntu-desktop &>/dev/null 2>&1; then echo "gnome"
  elif dpkg -l xubuntu-desktop &>/dev/null 2>&1; then echo "xfce"
  elif dpkg -l kubuntu-desktop &>/dev/null 2>&1; then echo "kde"
  elif dpkg -l xfce4 &>/dev/null 2>&1; then echo "xfce"
  else echo "unknown"
  fi
}

DE=$(detect_de)
log "Erkannte Desktop-Umgebung: $DE"

# ─── Pakete installieren ──────────────────────────────────────────────────────
log "Pakete installieren..."
apt-get update -qq
apt-get install -y \
  xrdp \
  xorgxrdp \
  xserver-xorg-video-dummy \
  dbus-x11

# ─── Dummy-Display konfigurieren (virtuelle Auflösung ohne Monitor) ───────────
log "Dummy-Videotreiber konfigurieren..."
mkdir -p /etc/X11/xorg.conf.d/

cat > /etc/X11/xorg.conf.d/10-headless-dummy.conf << 'XORGEOF'
# Virtueller Bildschirm für headless / kein HDMI
Section "Device"
    Identifier  "Dummy Device"
    Driver      "dummy"
    VideoRam    256000
EndSection

Section "Monitor"
    Identifier  "Dummy Monitor"
    HorizSync   28.0-80.0
    VertRefresh 48.0-75.0
    Modeline    "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync
    Modeline    "1280x720"   74.25 1280 1390 1430 1650  720  725  730  750 +hsync +vsync
EndSection

Section "Screen"
    Identifier  "Dummy Screen"
    Device      "Dummy Device"
    Monitor     "Dummy Monitor"
    DefaultDepth 24
    SubSection "Display"
        Depth    24
        Modes    "1920x1080" "1280x720"
        Virtual  1920 1080
    EndSubSection
EndSection
XORGEOF

# ─── xrdp konfigurieren ───────────────────────────────────────────────────────
log "xrdp konfigurieren..."

# Backup der Originalkonfig
[[ -f /etc/xrdp/xrdp.ini ]] && cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak

# Port und TLS-Einstellungen
sed -i 's/^port=3389/port=3389/' /etc/xrdp/xrdp.ini
sed -i 's/^#security_layer=negotiate/security_layer=negotiate/' /etc/xrdp/xrdp.ini
sed -i 's/^#crypt_level=high/crypt_level=high/' /etc/xrdp/xrdp.ini

# Desktop-Session konfigurieren
SESSION_FILE="/etc/xrdp/startwm.sh"
[[ -f $SESSION_FILE ]] && cp "$SESSION_FILE" "${SESSION_FILE}.bak"

case $DE in
  gnome)
    log "GNOME-Session für xrdp konfigurieren..."
    # GNOME braucht diese Umgebungsvariablen
    cat > /etc/xrdp/startwm.sh << 'SESSIONEOF'
#!/bin/sh
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
. /etc/X11/Xsession
exec /usr/bin/gnome-session
SESSIONEOF
    ;;
  xfce)
    log "XFCE-Session für xrdp konfigurieren..."
    cat > /etc/xrdp/startwm.sh << 'SESSIONEOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
SESSIONEOF
    ;;
  kde)
    log "KDE-Session für xrdp konfigurieren..."
    cat > /etc/xrdp/startwm.sh << 'SESSIONEOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startplasma-x11
SESSIONEOF
    ;;
  *)
    warn "Desktop-Umgebung unbekannt – Standard-startwm.sh bleibt erhalten."
    warn "Ggf. manuell anpassen: /etc/xrdp/startwm.sh"
    ;;
esac

[[ -f /etc/xrdp/startwm.sh ]] && chmod +x /etc/xrdp/startwm.sh

# ─── xrdp-User zur ssl-cert Gruppe (für TLS-Zugriff) ──────────────────────────
log "xrdp SSL-Zertifikat-Zugriff konfigurieren..."
adduser xrdp ssl-cert 2>/dev/null || true

# ─── Firewall-Regel (falls ufw aktiv) ─────────────────────────────────────────
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  log "ufw: Port 3389/tcp freigeben..."
  ufw allow 3389/tcp comment "RDP (xrdp)"
  ufw reload
else
  warn "ufw nicht aktiv – Port 3389 ggf. manuell in iptables freigeben."
fi

# ─── Dienste aktivieren und starten ──────────────────────────────────────────
log "xrdp-Dienste aktivieren..."
systemctl enable --now xrdp
systemctl enable --now xrdp-sesman

# ─── Status-Check ─────────────────────────────────────────────────────────────
sleep 1
if systemctl is-active --quiet xrdp; then
  log "xrdp läuft!"
else
  die "xrdp hat nicht gestartet. Logs: journalctl -u xrdp"
fi

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "════════════════════════════════════════════════════════"
echo -e " ${GREEN}RDP-Verbindung bereit${NC}"
echo "════════════════════════════════════════════════════════"
echo " Host:    $IP"
echo " Port:    3389"
echo " User:    $(logname 2>/dev/null || echo '<dein-username>')"
echo ""
echo " Windows:  mstsc.exe → $IP"
echo " macOS:    Microsoft Remote Desktop → $IP"
echo " Linux:    remmina / rdesktop / xfreerdp"
echo ""
echo " Logs:    journalctl -u xrdp -f"
echo " Config:  /etc/xrdp/xrdp.ini"
echo " Display: /etc/X11/xorg.conf.d/10-headless-dummy.conf"
echo "════════════════════════════════════════════════════════"
echo ""
warn "Hinweis: GNOME unter xrdp braucht ggf. einen Neustart"
warn "         oder 'systemctl restart xrdp' nach dem ersten Login."
