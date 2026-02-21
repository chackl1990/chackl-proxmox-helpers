post-pve-smart-standby.sh:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chackl1990/chackl-proxmox-helpers/refs/heads/main/post-pve-smart-standby.sh)"
```
# Proxmox HDD Spin-Down (LVM Fix)

## Problem
Opening the Proxmox **Disks** tab can wake sleeping HDDs because LVM (`lvs/pvs`) scans all devices.

## Fix
Exclude the media HDD from LVM scans using `global_filter`.

Edit:

```bash
nano /etc/lvm/lvm.conf
```

Update the existing `devices {}` block:

```conf
devices {
    global_filter = [
        "r|/dev/zd.*|",
        "r|/dev/rbd.*|",
        "r|/dev/disk/by-id/ata-YOUR_MEDIA_HDD_ID|",
        "a|.*|"
    ]
}
```

## Apply
```bash
pvscan --cache
vgscan --cache
systemctl restart pvedaemon pveproxy
```

## Verify
```bash
lvm config devices/global_filter
```

Your HDD should now stay in standby until actually accessed.
