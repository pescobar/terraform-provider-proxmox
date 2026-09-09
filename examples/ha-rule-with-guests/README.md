# Multiple guests in an HA rule

Seven QEMU guests, and HA rules built from a `locals` list that references the
guest resources rather than naming them as literal strings.

Requires **Proxmox VE 9 or newer**: `proxmox_ha_rule` does not exist before it,
and on Proxmox 8 placement is expressed with `hagroup` on the guest instead.

## The point of the `locals` list

```hcl
locals {
  ha_bal_guests = [
    proxmox_vm_qemu.playground_test, # 601
    proxmox_vm_qemu.playground_vm01, # 602
    # ...
  ]
}

resource "proxmox_ha_rule" "ha_bal" {
  resources = [for vm in local.ha_bal_guests : "vm:${vm.vmid}"]
  # ...
}
```

Referencing the resources is what orders the apply. Terraform builds its graph
from references, so every guest is created before the rule is written, and the
rule is updated before a guest is destroyed.

Writing the sids as literals instead —

```hcl
resources = ["vm:601", "vm:602"] # no dependency at all
```

— looks equivalent and is not. Terraform sees opaque strings, so a guest and a
rule that names it can be applied in either order. Adding a new guest and adding
it to a rule in the same apply then fails about half the time, with:

```
500 update HA rules failed: cannot use unmanaged resource(s) vm:608
```

## Guest settings that are easy to get wrong

* **`hastate = "started"`** — registers the guest with the HA manager. A guest
  that is not HA managed cannot be named by a rule at all; Proxmox rejects the
  whole rule, not just that entry.
* **`define_connection_info = false`** — defaults to `true`, and with `agent = 1`
  the provider then waits for a guest agent before finishing the create. A PXE
  booted machine with no operating system yet never answers, so the apply blocks
  until the create timeout.
* **no `hagroup`** — Proxmox 9 rejects it outright with `invalid parameter
  'group': ha groups have been migrated to rules`.

## `vmid` versus the resource id

These guests set `vmid` explicitly, so `vm.vmid` is available and reads
cleanly. For a guest that lets Proxmox allocate an id, `vmid` is **not** written
back to state, and `vm.vmid` would silently give `vm:0`. Use the id in that
case:

```hcl
resources = [for vm in local.guests : "vm:${element(split("/", vm.id), 2)}"]
```

## Removing a guest

Delete its `resource` block **and** its entry in the `locals` list in the same
change. Proxmox strips a destroyed guest's sid from every rule that references
it, so leaving the entry behind means the configuration tries to add back a
guest that no longer exists.

## Adapting it

Change `target_node`, the `pve-dev0*` names in `nodes`, `storage`, `bridge`, and
the `rule` identifiers. For rules a Proxmox 8 → 9 upgrade created, do not invent
identifiers — read them from the cluster and import. See
[the HA rule documentation](../../docs/resources/ha_rule.md).
