# HA Groups Data Source

Reads an existing High Availability group.

HA groups are a **Proxmox VE 8 and earlier** concept. Proxmox 9 replaced them
with HA rules and refuses to create one or assign a guest to one, so on a
Proxmox 9 cluster this data source finds nothing useful; see
[proxmox_ha_rule](../resources/ha_rule.md) instead.

## Example Usage

```hcl
data "proxmox_ha_groups" "balanced" {
  group_name = "HA_Balanced"
}

resource "proxmox_vm_qemu" "example" {
  # ...
  hastate = "started"
  hagroup = data.proxmox_ha_groups.balanced.group_name
}
```

## Argument Reference

| Argument     | Type     | Required | Description                |
| ------------ | -------- | -------- | -------------------------- |
| `group_name` | `string` | yes      | Name of the group to read. |

## Attribute Reference

| Attribute    | Type     | Description                                                                |
| ------------ | -------- | -------------------------------------------------------------------------- |
| `nodes`      | `string` | Member nodes, as `node:priority` pairs separated by commas.                  |
| `restricted` | `bool`   | Whether guests may only run on the listed nodes.                             |
| `nofailback` | `bool`   | Whether to leave a guest where it is once a higher priority node returns.    |
| `type`       | `string` | Group type as reported by Proxmox.                                           |
| `comment`    | `string` | Free text attached to the group.                                             |
