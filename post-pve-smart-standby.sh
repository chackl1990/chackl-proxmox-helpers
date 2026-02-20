cat >/usr/local/bin/pve-lvm-global-filter-selector.sh <<'EOF'
#!/usr/bin/env bash
# ======================================================================================
# Proxmox VE Helper-Style Script
# Title:   pve-lvm-global-filter-selector.sh
# Purpose: Interactive multi-select of disks to EXCLUDE from LVM scans via global_filter
#
# Fixes wakeups caused by lvs/pvs scanning all block devices.
# ======================================================================================

set -euo pipefail

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

have_cmd() { command -v "$1" >/dev/null 2>&1; }

LVMCONF="/etc/lvm/lvm.conf"

best_by_id_path() {
    local dev="$1"
    local id

    # Prefer ata-/scsi-/nvme- (without nvme-eui)
    for id in /dev/disk/by-id/ata-* /dev/disk/by-id/scsi-* /dev/disk/by-id/nvme-*; do
        [[ -e "$id" ]] || continue
        [[ "$id" == *"/dev/disk/by-id/nvme-eui"* ]] && continue
        if [[ "$(readlink -f "$id" 2>/dev/null || true)" == "$dev" ]]; then
            echo "$id"
            return 0
        fi
    done

    # Fallback: any by-id
    for id in /dev/disk/by-id/*; do
        [[ -e "$id" ]] || continue
        if [[ "$(readlink -f "$id" 2>/dev/null || true)" == "$dev" ]]; then
            echo "$id"
            return 0
        fi
    done

    echo "$dev"
}

# Robust disk enumeration: parse lsblk key="value" pairs (MODEL can have spaces!)
collect_disks_kv() {
    # TYPE=disk only, no loops/roms
    lsblk -dn -P -o NAME,TYPE,SIZE,ROTA,MODEL 2>/dev/null \
        | sed -n 's/.*TYPE="disk".*/&/p'
}

build_checklist_items() {
    local line name size rota model dev byid kind
    while IFS= read -r line; do
        # Extract KV fields safely
        name="$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<<"$line")"
        size="$(sed -n 's/.*SIZE="\([^"]*\)".*/\1/p' <<<"$line")"
        rota="$(sed -n 's/.*ROTA="\([^"]*\)".*/\1/p' <<<"$line")"
        model="$(sed -n 's/.*MODEL="\([^"]*\)".*/\1/p' <<<"$line")"

        [[ -n "$name" ]] || continue
        dev="/dev/${name}"
        byid="$(best_by_id_path "$dev")"

        kind="SSD"
        [[ "$rota" == "1" ]] && kind="HDD"

        # whiptail format: tag item status
        # tag must be unique and without spaces -> by-id is fine
        echo "${byid} ${name}(${kind},${size}) ${model:-unknown} OFF"
    done < <(collect_disks_kv)
}

read_existing_global_filter_block() {
    # Outputs the content INSIDE the [ ... ] for global_filter within devices{...}, if present.
    perl -0777 -ne '
        if (m/devices\s*\{.*?global_filter\s*=\s*\[(.*?)\]\s*;?/s) {
            print $1;
        }
    ' "$LVMCONF"
}

build_new_global_filter_array() {
    local selected_paths=("$@")
    local existing block

    existing="$(read_existing_global_filter_block || true)"

    # Normalize existing: keep non-empty, non-comment lines, drop accept-all (we re-add)
    # Also keep user custom rules.
    block="$(
        printf "%s\n" "$existing" \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            | sed -n '/^#/!p' \
            | sed -n '/^$/!p' \
            | grep -v '"a|.*|"' || true
    )"

    # Output: selected rejects first, then existing lines, then accept-all once.
    {
        for p in "${selected_paths[@]}"; do
            # Escape | just in case (rare)
            safe="${p//|/\\|}"
            echo "        \"r|${safe}|\","
        done

        if [[ -n "$block" ]]; then
            # Keep original indentation if present, otherwise indent
            while IFS= read -r l; do
                [[ -n "$l" ]] || continue
                # Ensure trailing comma stays as user wrote; we don't force it.
                if [[ "$l" =~ ^\".*\" ]]; then
                    echo "        $l"
                else
                    echo "        $l"
                fi
            done <<<"$block"
        fi

        echo "        \"a|.*|\""
    } | awk '!seen[$0]++'
}

apply_global_filter_update() {
    local selected_paths=("$@")
    local backup tmp
    backup="${LVMCONF}.bak-$(date +%Y%m%d-%H%M%S)"
    tmp="$(mktemp)"

    cp -a "$LVMCONF" "$backup"
    msg_ok "Backup created: $backup"

    # Build replacement array content
    local new_array
    new_array="$(mktemp)"
    build_new_global_filter_array "${selected_paths[@]}" >"$new_array"

    # Replace or insert global_filter inside devices { ... }
    perl -0777 -pe '
        my $new = do { local $/; <STDIN> };
        if (m/(devices\s*\{.*?)(global_filter\s*=\s*\[.*?\]\s*;?)(.*?\})/s) {
            my ($pre,$gf,$post) = ($1,$2,$3);
            $gf =~ s/global_filter\s*=\s*\[.*?\]\s*;?/global_filter = [\n'"$(cat "$new_array" | sed "s/'/\\\\'/g")"'\n    ]/s;
            $_ = $pre . $gf . $post . substr($_, pos($_) // 0);
        } elsif (m/devices\s*\{/s) {
            s/(devices\s*\{)/$1\n    global_filter = [\n'"$(cat "$new_array" | sed "s/'/\\\\'/g")"'\n    ]\n/s;
        } else {
            die "No devices { } block found in lvm.conf\n";
        }
    ' "$LVMCONF" >"$tmp" || die "Failed to patch $LVMCONF"

    install -m 644 "$tmp" "$LVMCONF"
    rm -f "$tmp" "$new_array"
    msg_ok "Updated: $LVMCONF"
}

restart_services() {
    msg_info "Refreshing LVM caches (best effort)"
    pvscan --cache >/dev/null 2>&1 || true
    vgscan --cache >/dev/null 2>&1 || true

    msg_info "Restarting Proxmox services (reload behavior)"
    systemctl restart pvedaemon >/dev/null 2>&1 || true
    systemctl restart pveproxy  >/dev/null 2>&1 || true
    msg_ok "Done"
}

show_selection_menu() {
    local items=()
    mapfile -t items < <(build_checklist_items)

    if [[ "${#items[@]}" -eq 0 ]]; then
        die "No disks found. Check lsblk output: lsblk -dn -P -o NAME,TYPE,SIZE,ROTA,MODEL"
    fi

    if have_cmd whiptail; then
        local args=()
        local entry tag status desc

        for entry in "${items[@]}"; do
            tag="$(awk '{print $1}' <<<"$entry")"
            status="$(awk '{print $NF}' <<<"$entry")"
            desc="$(sed -E 's/^[^ ]+ (.*) (ON|OFF)$/\1/' <<<"$entry")"
            args+=("$tag" "$desc" "$status")
        done

        msg_info "Select disks to EXCLUDE from LVM scans (SPACE toggle, ENTER confirm)"
        local sel
        sel="$(
            whiptail --title "LVM global_filter disk exclude" \
                --checklist "Choose disks to exclude from LVM scanning (prevents lvs/pvs wakeups):" \
                22 95 12 \
                "${args[@]}" \
                3>&1 1>&2 2>&3
        )" || die "Selection cancelled."

        # shellcheck disable=SC2206
        selections=($sel)
        for i in "${!selections[@]}"; do
            selections[$i]="${selections[$i]//\"/}"
        done
    else
        msg_warn "whiptail not found. Manual mode."
        msg_info "Available disks (by-id):"
        printf '%s\n' "${items[@]}" | awk '{print "  - " $1}'
        echo ""
        msg_info "Enter space-separated paths to exclude (e.g. /dev/disk/by-id/ata-...):"
        read -r -a selections
    fi
}

main() {
    need_root
    [[ -f "$LVMCONF" ]] || die "Missing $LVMCONF"
    have_cmd lsblk || die "lsblk not found"

    msg_info "This will modify LVM devices { global_filter = [ ... ] } to EXCLUDE selected disks."
    msg_info "Current global_filter (raw inside brackets):"
    read_existing_global_filter_block | sed 's/^/  /' || true
    echo ""

    selections=()
    show_selection_menu

    if [[ "${#selections[@]}" -eq 0 ]]; then
        die "No disks selected."
    fi

    msg_info "Selected to exclude:"
    for p in "${selections[@]}"; do
        echo "  - $p"
    done
    echo ""

    apply_global_filter_update "${selections[@]}"
    restart_services

    msg_ok "Finished. Opening Proxmox 'Disks' tab should no longer spin up excluded disks due to lvs/pvs."
}

main
EOF

chmod 755 /usr/local/bin/pve-lvm-global-filter-selector.sh
