# HA Rule Resource

Manages a High Availability rule on a Proxmox VE **9.0 or newer** cluster.

Proxmox 9 replaced HA groups with HA rules. Upgrading a cluster from 8 to 9
converts every group into a `node-affinity` rule automatically, so the most
common use of this resource is adopting rules the upgrade produced, with
`tofu import`, rather than creating them from scratch.

On Proxmox 8 this resource does not apply: use the `hagroup` argument on
`proxmox_vm_qemu` instead. Configuring it against an older cluster fails with a
clear error rather than an API one.

## Example Usage

### Node affinity: prefer a node, with priorities

```hcl
resource "proxmox_ha_rule" "prefer_node01" {
  rule      = "ha-rule-6ffa5f74-87f6"
  type      = "node-affinity"
  comment   = "ha-prefer-node01"
  resources = ["vm:120", "vm:301", "vm:608", "vm:701"]

  # Higher wins. A rule converted from an HA group keeps the priorities the
  # group had.
  nodes = {
    "pve-node01" = 5
    "pve-node02" = 1
    "pve-node03" = 1
  }

  # false (the default) prefers these nodes; true restricts the guests to
  # them, and they are stopped if none is available.
  strict = false
}
```

### Resource affinity: keep guests apart

Not expressible with HA groups, which is the main capability rules add.

```hcl
resource "proxmox_ha_rule" "keep_apart" {
  rule      = "db-replicas-apart"
  type      = "resource-affinity"
  comment   = "keep the database replicas on separate nodes"
  resources = ["vm:200", "vm:201"]
  affinity  = "negative"
}
```

## Argument Reference

| Argument    | Type           | Required | Description                                                                                                     |
| ----------- | -------------- | -------- | --------------------------------------------------------------------------------------------------------------- |
| `rule`      | `string`       | yes      | The rule identifier. Changing it replaces the rule.                                                               |
| `type`      | `string`       | yes      | `node-affinity` or `resource-affinity`. Changing it replaces the rule.                                             |
| `resources` | `set(string)`  | yes      | Guests the rule applies to, as `vm:<id>` or `ct:<id>`. Order is not significant.                                   |
| `nodes`     | `map(number)`  | no       | `node-affinity` only. Node name to priority; higher wins.                                                          |
| `strict`    | `bool`         | no       | `node-affinity` only. Restrict the guests to `nodes` rather than merely preferring them.                            |
| `affinity`  | `string`       | no       | `resource-affinity` only. `positive` keeps guests on one node, `negative` spreads them. Also reported on node-affinity rules, so it is computed when not set. |
| `comment`   | `string`       | no       | Free text. After an 8 → 9 upgrade this holds the name of the HA group the rule was converted from.                  |
| `disable`   | `bool`         | no       | Disable the rule without deleting it.                                                                             |

### Attribute Reference

| Attribute | Type     | Description                                                                                     |
| --------- | -------- | ----------------------------------------------------------------------------------------------- |
| `order`   | `number` | Evaluation order, assigned by Proxmox.                                                            |
| `digest`  | `string` | Checksum of the whole rules configuration. Shared by every rule rather than being per-rule, and **not** sent on update -- see the note below. |

## Importing

The import id is the rule identifier — the `rule` argument, not the resource
label.

### Finding the identifiers

An 8 → 9 upgrade converts each HA group into a rule but **does not reuse the
group's name**. It generates one and leaves the old name in `comment`:

```console
$ curl -sSk -H "Authorization: PVEAPIToken=$TOK" \
      "$PVE/cluster/ha/rules" | jq -r '.data[] | "\(.comment)\t\(.rule)"'
ha-bal              ha-rule-6e12c05d-c269
ha-prefer-node03    ha-rule-a53e0543-61b7
ha-prefer-node01    ha-rule-6ffa5f74-87f6
```

or on a node directly:

```console
$ pvesh get /cluster/ha/rules --output-format json | jq -r '.[] | "\(.comment)\t\(.rule)"'
```

Those identifiers are minted during the upgrade, so **they differ per cluster**:
the ones from a rehearsal are not the ones production will get. Read them off
each cluster after upgrading rather than writing them in advance.

### Importing with a config-driven import block

Preferred, because OpenTofu writes the configuration for you and you review it
before anything is applied.

```hcl
import {
  to = proxmox_ha_rule.ha_bal
  id = "ha-rule-6e12c05d-c269"
}
```

```console
$ tofu plan -generate-config-out=ha_rules.tf
$ # review ha_rules.tf, then
$ tofu apply
```

The generated block contains the rule exactly as the cluster has it, including
the `nodes` priorities the original group carried and the `resources` list.

### Importing with the CLI

```console
$ tofu import proxmox_ha_rule.ha_bal ha-rule-6e12c05d-c269
```

This needs a matching `resource` block to exist first, or the import fails.

### After importing

Run `tofu plan` and expect **no changes**. A diff means the configuration and
the cluster disagree, and the usual causes are:

* `resources` written in a different order — harmless, it is a set, and no diff
  should appear; if one does, the order is not the cause;
* `nodes` priorities omitted — a converted group keeps its weightings, so
  `pve-node01 = 5` has to be in the configuration too;
* `affinity` omitted — Proxmox reports `positive` on node-affinity rules as
  well as resource-affinity ones, so leave it unset and let it stay computed
  rather than guessing a value.

### Every referenced guest must already be HA managed

Proxmox validates the whole `resources` list on every write, not just the
entries that changed:

```
500 update HA rules failed: cannot use unmanaged resource(s) vm:608
```

A guest is HA managed when it has `hastate` set — see `hastate` on
[proxmox_vm_qemu](vm_qemu.md). Two consequences worth knowing before importing:

* a guest you add to a rule needs `hastate` **first**, so reference the guest
  resource in `resources` and let Terraform order them;
* a rule that already references a guest which has since become unmanaged
  cannot be written **at all** until that sid is removed or the guest is
  managed again — including writes that have nothing to do with that guest.

Check for stale references before importing:

```console
$ comm -13 \
    <(curl -sSk "${auth[@]}" "$PVE/cluster/ha/resources" | jq -r '.data[].sid' | sort) \
    <(curl -sSk "${auth[@]}" "$PVE/cluster/ha/rules" | jq -r '.data[].resources' | tr ',' '\n' | sort -u)
```

Anything printed is referenced by a rule but not HA managed, and will block
updates to whichever rule holds it.

## Notes on migrating from HA groups

The upgrade moves guest membership out of the guest and into the rule. Every HA
resource comes back with **no group at all**, and Proxmox 9 refuses to set one:

```
500 invalid parameter 'group': ha groups have been migrated to rules
```

So a configuration that still sets `hagroup` on `proxmox_vm_qemu` fails to
apply after the upgrade. Remove `hagroup` before the first apply; keep
`hastate`, which is unaffected.

## Concurrent modification

Proxmox stores every HA rule in one file and reports a single `digest` over all
of them. Passing that digest back on a write makes Proxmox reject the write if
anything changed the file in the meantime.

This provider reads `digest` but does not send it, because in Terraform's
execution model the value is always potentially stale: it is read during
refresh and would be written during apply, with no re-read in between. Two
routine situations invalidate it —

* **destroying a guest**, because Proxmox strips its sid from any rule that
  references it, rewriting the file before Terraform updates the rule;
* **updating two rules in one apply**, because the first write changes the
  digest the second is holding.

The practical consequence is last-write-wins: if something outside Terraform
edits a rule between refresh and apply, that edit is overwritten rather than
reported. Given Terraform assumes ownership of what it manages, that is the
behaviour that lets ordinary applies succeed.
