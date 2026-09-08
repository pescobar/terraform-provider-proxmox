# Storage ISO Resource

Downloads an ISO image onto a Proxmox storage, from a URL reachable by the
node rather than by the machine running OpenTofu.

Every argument forces replacement: the resource describes a downloaded file,
so changing any part of it means fetching a different one.

## Example Usage

```hcl
resource "proxmox_storage_iso" "debian" {
  pve_node = "pve-node01"
  storage  = "local"
  filename = "debian-13-netinst-amd64.iso"
  url      = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.0.0-amd64-netinst.iso"

  checksum           = "0e2f2e1a7f0f5b0b0d0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60"
  checksum_algorithm = "sha256"
}
```

The result can be attached to a guest through the `cdrom` block of
[proxmox_vm_qemu](vm_qemu.md):

```hcl
disks {
  ide {
    ide2 {
      cdrom {
        iso = "local:iso/debian-13-netinst-amd64.iso"
      }
    }
  }
}
```

## Argument Reference

| Argument             | Type     | Required | Description                                                        |
| -------------------- | -------- | -------- | ------------------------------------------------------------------ |
| `pve_node`           | `string` | yes      | Node that performs the download.                                    |
| `storage`            | `string` | yes      | Storage to write to. It must accept `iso` content.                  |
| `filename`           | `string` | yes      | Name to store the image under.                                      |
| `url`                | `string` | yes      | Source URL, fetched by the node.                                    |
| `checksum`           | `string` | no       | Expected checksum of the downloaded file.                           |
| `checksum_algorithm` | `string` | no       | Algorithm for `checksum`, for example `sha256`.                     |
