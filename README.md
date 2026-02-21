# Proxmox HDD Spin-Down (SMART + LVM Fix)

## Problem
Opening the Proxmox **Disks** tab or use api with smart will wake sleeping HDDs because LVM (`lvs/pvs`) scans all devices or smartchecks.

## Fix Smart
Patch: post-pve-smart-standby.sh:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chackl1990/chackl-proxmox-helpers/refs/heads/main/post-pve-smart-standby.sh)"
```
## Fix LVM
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
        "r|/dev/disk/by-id/ata-YOUR_MEDIA_HDD_ID1|",
        "r|/dev/disk/by-id/ata-YOUR_MEDIA_HDD_ID2|",
        ...
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
