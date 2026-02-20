#!/usr/bin/env bash
# ======================================================================================
# Proxmox VE Helper-Style Script
# Title:   pve-lvm-global-filter-selector.sh
# Purpose: Interactive multi-select of disks to EXCLUDE from LVM scans via global_filter
#
# What it does:
#   - Shows a checklist of local disks (prefers /dev/disk/by-id stable paths)
#   - Lets you select multiple disks
#   - Updates /etc/lvm/lvm.conf by MODIFYING/ADDING devices { global_filter = [ ... ] }
#   - Preserves existing global_filter entries as much as possible:
#       * keeps custom entries
#       * ensures final "a|.*|" exists (accept all remaining)
#       * inserts selected rejects BEFORE accept-all
#   - Creates a timestamped backup
#
# Notes:
#   - This does NOT patch Proxmox Perl files. It fixes the actual wakeup cause (lvs/pvs scans).
#   - Requires whiptail (usually present). If not present, falls back to a simple prompt.
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

LVMCONF="/etc/lvm/lvm.conf"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Return best stable device path (by-id) for /dev/sdX, /dev/nvme0n1, etc.
best_by_id_path() {
    local dev="$1" base idpath
    base="$(basename "$dev")"

    # Prefer ata-/scsi-/nvme- (not nvme-eui), avoid wwn if possible
    idpath="$(ls -1 /dev/disk/by-id 2>/dev/null \
        | grep -E '^(ata-|scsi-|nvme-)' \
        | grep -vE '^nvme-eui' \
        | while read -r id; do
            if [[ "$(readlink -f "/dev/disk/by-id/$id" 2>/dev/null || true)" == "$dev" ]]; then
                echo "/dev/disk/by-id/$id"
                break
            fi
        done
    )"

    if [[ -n "${idpath:-}" ]]; then
        echo "$idpath"
        return 0
    fi

    # Fallback: any by-id link
    idpath="$(ls -1 /dev/disk/by-id 2>/dev/null \
        | while read -r id; do
            if [[ "$(readlink -f "/dev/disk/by-id/$id" 2>/dev/null || true)" == "$dev" ]]; then
                echo "/dev/disk/by-id/$id"
                break
            fi
        done
    )"

    if [[ -n "${idpath:-}" ]]; then
        echo "$idpath"
        return 0
    fi

    # Last resort: raw dev path
    echo "$dev"
}

# Collect candidate disks: type "disk", local
collect_disks() {
    # NAME MODEL SIZE ROTA TYPE
    # ROTA: 1 HDD, 0 SSD/NVMe
    lsblk -dn -o NAME,MODEL,SIZE,ROTA,TYPE 2>/dev/null \
        | awk '$5=="disk"{print}'
}

# Build whiptail checklist items: tag + description + status
build_checklist_items() {
    local line name model size rota type dev byid kind
    while IFS= read -r line; do
        name="$(awk '{print $1}' <<<"$line")"
        model="$(awk '{ $1=""; $4=""; $5=""; sub(/^ +/,""); print }' <<<"$line")"
        size="$(awk '{print $3}' <<<"$line")"
        rota="$(awk '{print $4}' <<<"$line")"
        type="$(awk '{print $5}' <<<"$line")"
        dev="/dev/${name}"
        byid="$(best_by_id_path "$dev")"
        kind="SSD"
        [[ "$rota" == "1" ]] && kind="HDD"
        # tag must not contain spaces
        echo "${byid} ${name}(${kind},${size}) ${model:-""} OFF"
    done < <(collect_disks)
}

# Parse existing global_filter array entries (between [ and ];) if present.
# Output one entry per line, stripped.
read_existing_global_filter_entries() {
    awk '
        BEGIN{in_devices=0; in_gf=0}
        /^\s*devices\s*\{/ {in_devices=1}
        in_devices && /^\s*global_filter\s*=\s*\[/ {in_gf=1; next}
        in_gf {
            if ($0 ~ /^\s*\]\s*;?\s*$/) {in_gf=0; next}
            gsub(/^[ \t]+|[ \t]+$/, "", $0)
            if ($0 != "") print $0
        }
        in_devices && /^\s*\}/ {in_devices=0}
    ' "$LVMCONF"
}

# Write new global_filter block, preserving existing entries as much as possible.
# - Remove any existing "a|.*|" (we will add one at end)
# - Keep other existing entries
# - Add selected reject rules (r|PATH|) before accept-all
generate_new_global_filter_block() {
    local selected_paths=("$@")
    local tmp_existing tmp_final
    tmp_existing="$(mktemp)"
    tmp_final="$(mktemp)"

    read_existing_global_filter_entries >"$tmp_existing" || true

    # Normalize: keep all entries except accept-all; also drop empty/comment-only lines
    awk '
        {
            line=$0
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line ~ /^#/ || line=="") next
            # drop accept-all rules (we re-add at end)
            if (line ~ /"a\|\.\*\|"/) next
            print line
        }
    ' "$tmp_existing" >"$tmp_final"

    # Output block lines (indented 8 spaces, common style inside devices {})
    # First selected rejects (unique)
    {
        for p in "${selected_paths[@]}"; do
            # escape '|' in path (unlikely)
            safe="${p//|/\\|}"
            echo "        \"r|${safe}|\","
        done

        # Keep existing entries (but avoid duplicates of our selected rejects)
        awk -v OFS="" '
            {
                line=$0
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                print line
            }
        ' "$tmp_final"

        # Ensure accept-all at end
        echo "        \"a|.*|\""
    } | awk '
        BEGIN{
            seen[""]=1
        }
        {
            # de-dupe exact lines
            if (!seen[$0]++) print $0
        }
    '

    rm -f "$tmp_existing" "$tmp_final"
}

# Update lvm.conf: replace existing global_filter block if present, otherwise insert into devices { }.
apply_global_filter_update() {
    local selected_paths=("$@")
    local backup tmp new_block has_gf
    backup="${LVMCONF}.bak-$(date +%Y%m%d-%H%M%S)"
    tmp="$(mktemp)"

    cp -a "$LVMCONF" "$backup"
    msg_ok "Backup created: $backup"

    # Prepare new block content
    new_block="$(mktemp)"
    {
        echo "    global_filter = ["
        generate_new_global_filter_block "${selected_paths[@]}"
        echo "    ]"
    } >"$new_block"

    # Detect if global_filter exists inside devices block
    if awk '
        BEGIN{in_devices=0; found=0}
        /^\s*devices\s*\{/ {in_devices=1}
        in_devices && /^\s*global_filter\s*=\s*\[/ {found=1}
        in_devices && /^\s*\}/ {in_devices=0}
        END{exit(found?0:1)}
    ' "$LVMCONF"; then
        has_gf=1
    else
        has_gf=0
    fi

    if [[ "$has_gf" -eq 1 ]]; then
        msg_info "Updating existing devices { global_filter = [ ... ] } block"

        awk -v NEWBLOCKFILE="$new_block" '
            BEGIN{
                in_devices=0; in_gf=0;
                while ((getline line < NEWBLOCKFILE) > 0) newblock[++n]=line;
                close(NEWBLOCKFILE);
            }
            /^\s*devices\s*\{/ {in_devices=1; print; next}
            in_devices && /^\s*global_filter\s*=\s*\[/ {
                # print replacement block
                for (i=1; i<=n; i++) print newblock[i];
                in_gf=1;
                next
            }
            in_gf {
                # skip until closing bracket ]
                if ($0 ~ /^\s*\]\s*;?\s*$/) { in_gf=0; next }
                next
            }
            in_devices && /^\s*\}/ {in_devices=0; print; next}
            {print}
        ' "$LVMCONF" >"$tmp"
    else
        msg_info "No global_filter found in devices { } - inserting a new one"

        awk -v NEWBLOCKFILE="$new_block" '
            BEGIN{
                in_devices=0; inserted=0;
                while ((getline line < NEWBLOCKFILE) > 0) newblock[++n]=line;
                close(NEWBLOCKFILE);
            }
            /^\s*devices\s*\{/ {
                in_devices=1;
                print;
                if (!inserted) {
                    for (i=1; i<=n; i++) print newblock[i];
                    inserted=1;
                }
                next
            }
            in_devices && /^\s*\}/ {in_devices=0; print; next}
            {print}
        ' "$LVMCONF" >"$tmp"
    fi

    # Replace file atomically-ish
    install -m 644 "$tmp" "$LVMCONF"
    rm -f "$tmp" "$new_block"

    msg_ok "Updated: $LVMCONF"
}

restart_relevant_services() {
    msg_info "Refreshing LVM caches"
    pvscan --cache >/dev/null 2>&1 || true
    vgscan --cache >/dev/null 2>&1 || true

    msg_info "Restarting Proxmox services (optional but recommended)"
    systemctl restart pvedaemon >/dev/null 2>&1 || true
    systemctl restart pveproxy  >/dev/null 2>&1 || true
    msg_ok "Done"
}

show_current_global_filter() {
    msg_info "Current devices { global_filter } entries:"
    if read_existing_global_filter_entries | sed 's/^/  /' | grep -q .; then
        read_existing_global_filter_entries | sed 's/^/  /'
    else
        echo "  (none found)"
    fi
}

main() {
    need_root
    [[ -f "$LVMCONF" ]] || die "Missing $LVMCONF"
    have_cmd lsblk || die "lsblk not found"

    msg_info "This will configure LVM global_filter to IGNORE selected disks (prevents lvs/pvs wakeups)."
    show_current_global_filter
    echo ""

    local selections=()
    if have_cmd whiptail; then
        # Build checklist args
        mapfile -t items < <(build_checklist_items)
        if [[ "${#items[@]}" -eq 0 ]]; then
            die "No disks found via lsblk."
        fi

        # whiptail expects: tag item status triplets
        local args=()
        local i
        for i in "${items[@]}"; do
            # split into 3 fields: tag desc status
            tag="$(awk '{print $1}' <<<"$i")"
            status="$(awk '{print $NF}' <<<"$i")"
            desc="$(sed -E 's/^[^ ]+ (.*) (ON|OFF)$/\1/' <<<"$i")"
            args+=("$tag" "$desc" "$status")
        done

        # Show checklist
        msg_info "Select disks to EXCLUDE from LVM scans (SPACE to toggle, ENTER to confirm)."
        sel="$(
            whiptail --title "LVM global_filter disk exclude" \
                --checklist "Choose disks to exclude from LVM scanning (prevents spin-up):" \
                22 90 12 \
                "${args[@]}" \
                3>&1 1>&2 2>&3
        )" || die "Selection cancelled."

        # whiptail returns quoted items like: "/dev/disk/by-id/ata-..." "/dev/disk/by-id/..."
        # Convert to array
        # shellcheck disable=SC2206
        selections=($sel)
        # strip quotes
        for i in "${!selections[@]}"; do
            selections[$i]="${selections[$i]//\"/}"
        done
    else
        msg_warn "whiptail not found. Falling back to manual input."
        msg_info "Available disks (best by-id shown):"
        build_checklist_items | awk '{print "  - " $1 " (" $2 ")"}'
        echo ""
        msg_info "Enter space-separated paths to exclude (e.g. /dev/disk/by-id/ata-... /dev/disk/by-id/scsi-...):"
        read -r -a selections
    fi

    if [[ "${#selections[@]}" -eq 0 ]]; then
        die "No disks selected."
    fi

    msg_info "Will exclude these from LVM scans:"
    for p in "${selections[@]}"; do
        echo "  - $p"
    done
    echo ""

    apply_global_filter_update "${selections[@]}"
    show_current_global_filter
    restart_relevant_services

    msg_ok "If you open Proxmox 'Disks' tab now, it should no longer spin up excluded disks due to lvs/pvs."
}

main
