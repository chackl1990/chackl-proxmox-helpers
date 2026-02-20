#!/usr/bin/env bash
# ======================================================================================
#  Proxmox VE Helper-Style Script
#  Title:   post-pve-smart-standby.sh
#  Purpose: Patch PVE so SMART queries do NOT wake sleeping HDDs (smartctl -n standby)
#
#  What it does:
#    - Patches /usr/share/perl5/PVE/Diskmanage.pm:
#         my $cmd = [$SMARTCTL, '-H'];
#      becomes:
#         my $cmd = [$SMARTCTL, '-n', 'standby', '-H'];
#      (idempotent, safe to run multiple times)
#
#    - Adds a marker comment so it won’t patch twice.
#    - Creates an APT DPkg::Post-Invoke hook to re-apply after updates.
#    - Restarts pvedaemon + pveproxy to reload Perl modules.
#
#  Usage:
#    bash post-pve-smart-standby.sh
#    bash post-pve-smart-standby.sh --remove
#
#  Notes:
#    - This ONLY prevents SMART calls from waking disks.
#    - It does NOT fix wakeups caused by other tools (e.g. lvs/pvs scans).
# ======================================================================================

set -euo pipefail

# ---- helper-script style output -------------------------------------------------------
RD=$'\033[01;31m'
GN=$'\033[01;32m'
YW=$'\033[01;33m'
BL=$'\033[01;34m'
CL=$'\033[m'

msg_info() { echo -e "${BL}[*]${CL} $*"; }
msg_ok()   { echo -e "${GN}[✓]${CL} $*"; }
msg_warn() { echo -e "${YW}[!]${CL} $*"; }
msg_err()  { echo -e "${RD}[✗]${CL} $*"; }
die()      { msg_err "$*"; exit 1; }

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Please run as root."
}

# ---- config ----------------------------------------------------------------------------
TARGET="/usr/share/perl5/PVE/Diskmanage.pm"
MARKER="PVE_SMARTCTL_STANDBY_ONLY_PATCH"
PATCH_HELPER="/usr/local/bin/pve-smartctl-standby-only-patch.sh"
APT_HOOK="/etc/apt/apt.conf.d/zz-pve-smartctl-standby-only"

REMOVE=0
if [[ "${1:-}" == "--remove" ]]; then
    REMOVE=1
fi

restart_pve_services() {
    msg_info "Restarting Proxmox services to reload Perl modules"
    systemctl restart pvedaemon >/dev/null 2>&1 || true
    systemctl restart pveproxy  >/dev/null 2>&1 || true
    msg_ok "Services restarted (pvedaemon, pveproxy)"
}

install_patch_helper() {
    msg_info "Installing patch helper: ${PATCH_HELPER}"
    cat >"${PATCH_HELPER}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

FILE="/usr/share/perl5/PVE/Diskmanage.pm"
MARKER="PVE_SMARTCTL_STANDBY_ONLY_PATCH"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root"
    exit 1
fi

if [[ ! -f "$FILE" ]]; then
    echo "File not found: $FILE"
    exit 1
fi

# Already patched?
if grep -q "$MARKER" "$FILE"; then
    echo "Already patched: $FILE"
    exit 0
fi

# Backup
cp -a "$FILE" "${FILE}.bak-$(date +%Y%m%d-%H%M%S)"

# Defensive fix: if a previous bad patch removed $SMARTCTL, repair that broken line
perl -i -pe '
    if (/^\s*my\s+\$cmd\s*=\s*\[.*\];\s*$/ && /standby/ && /-H/ && !/\$SMARTCTL/) {
        $_ = "    my \$cmd = [\$SMARTCTL, \x27-n\x27, \x27standby\x27, \x27-H\x27];\n";
    }
' "$FILE"

# Insert "-n standby" right after $SMARTCTL on the cmd init line containing '-H', only if not already present
perl -i -pe '
    if (/^\s*my\s+\$cmd\s*=\s*\[\s*\$SMARTCTL\s*,/ && !/\x27-n\x27/ && /\x27-H\x27/) {
        s/\[\s*\$SMARTCTL\s*,\s*/[\$SMARTCTL, \x27-n\x27, \x27standby\x27, /;
    }
' "$FILE"

# Sanity check (single quotes to avoid shell expansion)
if ! grep -q 'my \$cmd = \[\$SMARTCTL, '"'"'-n'"'"', '"'"'standby'"'"', '"'"'-H'"'"'\];' "$FILE"; then
    echo "Patch did not apply cleanly."
    echo "Check file and backups: ${FILE}.bak-*"
    exit 1
fi

{
    echo ""
    echo "# ${MARKER}"
} >>"$FILE"

echo "Patched OK: $FILE"
EOF
    chmod 755 "${PATCH_HELPER}"
    msg_ok "Installed patch helper"
}

apply_patch_now() {
    msg_info "Applying SMART no-wakeup patch now"
    "${PATCH_HELPER}" >/dev/null
    msg_ok "Patch applied (or already present)"
}

install_apt_hook() {
    msg_info "Installing APT Post-Invoke hook: ${APT_HOOK}"
    cat >"${APT_HOOK}" <<EOF
DPkg::Post-Invoke { "${PATCH_HELPER}"; };
EOF
    chmod 644 "${APT_HOOK}"
    msg_ok "APT hook installed (patch will be re-applied after upgrades)"
}

remove_everything() {
    msg_info "Removing APT hook and patch helper"
    rm -f "${APT_HOOK}" || true
    rm -f "${PATCH_HELPER}" || true
    msg_ok "Removed hook + helper"

    msg_warn "This does NOT automatically restore Diskmanage.pm."
    msg_warn "Restore from backup if needed:"
    msg_warn "  ls -1 ${TARGET}.bak-*"
}

# ---- main ------------------------------------------------------------------------------
need_root

msg_info "Proxmox SMART no-wakeup patch (smartctl -n standby)"

if [[ "${REMOVE}" -eq 1 ]]; then
    remove_everything
    exit 0
fi

[[ -f "${TARGET}" ]] || die "Target not found: ${TARGET}"

install_patch_helper
apply_patch_now
install_apt_hook
restart_pve_services

msg_ok "Done."
msg_warn "Reminder: GUI 'Disks' tab wakeups can still happen from other scans (e.g. lvs/pvs)."
