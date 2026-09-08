# LXC Disk Resource

Attaches an additional mount point to an existing `proxmox_lxc` container.

The container's own root filesystem is configured with the `rootfs` block on
[proxmox_lxc](lxc.md); this resource is for the extra mount points beyond it.

## Example Usage

```hcl
resource "proxmox_lxc_disk" "data" {
  container = 100
  slot      = 0
  mp        = "/mnt/data"
  storage   = "local-lvm"
  size      = "8G"

  backup    = true
  quota     = false

  mountoptions {
    noatime = true
    nodev   = true
  }
}
```

## Argument Reference

Changing `container` replaces the mount point rather than moving it.

| Argument        | Type     | Required | Description                                                              |
| --------------- | -------- | -------- | ------------------------------------------------------------------------ |
| `container`     | `number` | yes      | Guest id of the container to attach to. Changing it forces replacement.    |
| `slot`          | `number` | yes      | Mount point index, so `0` becomes `mp0`.                                   |
| `mp`            | `string` | yes      | Path inside the container.                                                 |
| `storage`       | `string` | yes      | Storage the volume is allocated on.                                        |
| `size`          | `string` | yes      | Size of the volume, for example `8G`.                                      |
| `acl`           | `bool`   | no       | Enable POSIX ACLs.                                                         |
| `backup`        | `bool`   | no       | Include the mount point in backups.                                        |
| `quota`         | `bool`   | no       | Enable user quotas. Unprivileged containers do not support this.           |
| `replicate`     | `bool`   | no       | Include the volume in storage replication.                                 |
| `shared`        | `bool`   | no       | Mark the volume as shared between nodes.                                   |
| `mountoptions`  | `block`  | no       | Mount flags: `noatime`, `nodev`, `noexec`, `nosuid`, each a `bool`.        |

## Attribute Reference

| Attribute | Type     | Description                                          |
| --------- | -------- | ---------------------------------------------------- |
| `volume`  | `string` | Volume identifier Proxmox allocated for the disk.      |
