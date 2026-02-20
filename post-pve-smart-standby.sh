cat >/usr/local/bin/pve-lvm-global-filter-selector-v3.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

RD=$'\033[01;31m'
GN=$'\033[01;32m'
YW=$'\033[01;33m'
BL=$'\033[01;34m'
CL=$'\033[m'

msg_info() { echo -e "${BL}[*]${CL} $*"; }
msg_ok()   { echo -e "${GN}[✓]${CL} $*"; }
msg_warn() { echo -e "${YW}[!]${CL} $*"; }
msg_err()  { echo -e "${RD}[✗]${CL} $*"; }

trap 'msg_err "Script aborted (line $LINENO). Exit=$?"; exit 1' ERR

need_root() { [[ "$(id -u)" -eq 0 ]] || { msg_err "Run as root"; exit 1; }; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

LVMCONF="/etc/lvm/lvm.conf"

best_by_id_path() {
    local dev="$1"
    local id
    for id in /dev/disk/by-id/ata-* /dev/disk/by-id/scsi-* /dev/disk/by-id/nvme-*; do
        [[ -e "$id" ]] || continue
        [[ "$id" == *"/dev/disk/by-id/nvme-eui"* ]] && continue
        if [[ "$(readlink -f "$id" 2>/dev/null || true)" == "$dev" ]]; then
            echo "$id"
            return 0
        fi
    done
    for id in /dev/disk/by-id/*; do
        [[ -e "$id" ]] || continue
        if [[ "$(readlink -f "$id" 2>/dev/null || true)" == "$dev" ]]; then
            echo "$id"
            return 0
        fi
    done
    echo "$dev"
}

collect_disks_kv() {
    # MODEL can contain spaces -> use KEY="VALUE" format
    lsblk -dn -P -o NAME,TYPE,SIZE,ROTA,MODEL 2>/dev/null \
        | sed -n 's/.*TYPE="disk".*/&/p'
}

build_checklist_items() {
    local line name size rota model dev byid kind
    while IFS= read -r line; do
        name="$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<<"$line")"
        size="$(sed -n 's/.*SIZE="\([^"]*\)".*/\1/p' <<<"$line")"
        rota="$(sed -n 's/.*ROTA="\([^"]*\)".*/\1/p' <<<"$line")"
        model="$(sed -n 's/.*MODEL="\([^"]*\)".*/\1/p' <<<"$line")"
        [[ -n "$name" ]] || continue
        dev="/dev/${name}"
        byid="$(best_by_id_path "$dev")"
        kind="SSD"
        [[ "$rota" == "1" ]] && kind="HDD"
        echo "${byid} ${name}(${kind},${size}) ${model:-unknown} OFF"
    done < <(collect_disks_kv)
}

read_existing_global_filter_inner() {
    perl -0777 -ne '
        if (m/devices\s*\{.*?global_filter\s*=\s*\[(.*?)\]\s*;?/s) {
            print $1;
        }
    ' "$LVMCONF" || true
}

build_new_filter_lines() {
    # Params: selected paths...
    local selected_paths=("$@")
    local existing cleaned

    existing="$(read_existing_global_filter_inner)"
    cleaned="$(
        printf "%s\n" "$existing" \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            | sed -n '/^#/!p' | sed -n '/^$/!p' \
            | grep -v '"a|.*|"' || true
    )"

    {
        for p in "${selected_paths[@]}"; do
            safe="${p//|/\\|}"
            echo "        \"r|${safe}|\","
        done

        if [[ -n "$cleaned" ]]; then
            while IFS= read -r l; do
                [[ -n "$l" ]] || continue
                # keep as-is, just indent consistently if not already
                if [[ "$l" =~ ^\" ]]; then
                    echo "        $l"
                else
                    echo "        $l"
                fi
            done <<<"$cleaned"
        fi

        echo "        \"a|.*|\""
    } | awk '!seen[$0]++'
}

apply_global_filter_update() {
    local selected_paths=("$@")
    local backup newfile

    backup="${LVMCONF}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$LVMCONF" "$backup"
    msg_ok "Backup created: $backup"

    newfile="$(mktemp)"
    build_new_filter_lines "${selected_paths[@]}" >"$newfile"

    # Use Perl to update lvm.conf robustly:
    # - If devices{... global_filter=[...] ...} exists: replace only that block
    # - Else: insert global_filter into devices{ ... } right after opening brace
    NEWFILE="$newfile" perl -0777 -i -pe '
        my $nf = $ENV{NEWFILE};
        open(my $fh, "<", $nf) or die "cannot open NEWFILE: $nf\n";
        my $new = do { local $/; <$fh> };
        close($fh);

        if (m/(devices\s*\{.*?)(global_filter\s*=\s*\[.*?\]\s*;?)(.*?\})/s) {
            my ($pre,$gf,$post) = ($1,$2,$3);
            $gf = "global_filter = [\n${new}\n    ]";
            $_ = $pre . $gf . $post . substr($_, length($pre.$2.$post));
        } elsif (m/devices\s*\{/s) {
            s/(devices\s*\{)/$1\n    global_filter = [\n${new}\n    ]\n/s;
        } else {
            die "No devices { } block found in lvm.conf\n";
        }
    ' "$LVMCONF"

    rm -f "$newfile"
    msg_ok "Updated: $LVMCONF"
}

restart_services() {
    msg_info "Refreshing LVM caches"
    pvscan --cache >/dev/null 2>&1 || true
    vgscan --cache >/dev/null 2>&1 || true

    msg_info "Restarting Proxmox services"
    systemctl restart pvedaemon >/dev/null 2>&1 || true
    systemctl restart pveproxy  >/dev/null 2>&1 || true
    msg_ok "Done"
}

main() {
    need_root
    [[ -f "$LVMCONF" ]] || { msg_err "Missing $LVMCONF"; exit 1; }
    have_cmd lsblk || { msg_err "lsblk not found"; exit 1; }

    msg_info "LVM global_filter selector (exclude selected disks from LVM scans)"
    msg_info "This prevents lvs/pvs from spinning up sleeping media HDDs."
    echo ""

    mapfile -t items < <(build_checklist_items)
    if [[ "${#items[@]}" -eq 0 ]]; then
        msg_err "No disks found. Check: lsblk -dn -P -o NAME,TYPE,SIZE,ROTA,MODEL"
        exit 1
    fi

    selections=()

    if have_cmd whiptail && [[ -t 0 ]]; then
        local args=()
        for entry in "${items[@]}"; do
            tag="$(awk '{print $1}' <<<"$entry")"
            status="$(awk '{print $NF}' <<<"$entry")"
            desc="$(sed -E 's/^[^ ]+ (.*) (ON|OFF)$/\1/' <<<"$entry")"
            args+=("$tag" "$desc" "$status")
        done

        msg_info "Select disks to EXCLUDE (SPACE toggle, ENTER confirm)"
        sel="$(
            whiptail --title "LVM global_filter disk exclude" \
                --checklist "Choose disks to exclude from LVM scanning:" \
                22 95 12 \
                "${args[@]}" \
                3>&1 1>&2 2>&3
        )" || { msg_warn "Selection cancelled"; exit 1; }

        # shellcheck disable=SC2206
        selections=($sel)
        for i in "${!selections[@]}"; do
            selections[$i]="${selections[$i]//\"/}"
        done
    else
        msg_warn "No whiptail or no TTY detected. Manual mode:"
        printf '%s\n' "${items[@]}" | awk '{print "  - " $1}'
        echo ""
        msg_info "Enter space-separated paths to exclude:"
        read -r -a selections
    fi

    if [[ "${#selections[@]}" -eq 0 ]]; then
        msg_err "No disks selected."
        exit 1
    fi

    msg_info "Selected to exclude:"
    for p in "${selections[@]}"; do
        echo "  - $p"
    done
    echo ""

    apply_global_filter_update "${selections[@]}"
    restart_services

    msg_ok "Finished."
}

main
EOF

chmod 755 /usr/local/bin/pve-lvm-global-filter-selector-v3.sh
