locals {
  # Guests that belong to the ha-bal rule.  Referencing the resources here is
  # what makes Terraform create them before it writes the rule -- the rule
  # depends on the local, the local depends on the guests.
  #
  # A literal list such as ["vm:601", "vm:602"] would apply in the right order
  # only by luck: Terraform sees opaque strings and no dependency at all.
  ha_bal_guests = [
    proxmox_vm_qemu.playground_test,      # 601
    proxmox_vm_qemu.playground_vm01,      # 602
    proxmox_vm_qemu.playground_vm02,      # 604
    proxmox_vm_qemu.playground_vm03,      # 605
    proxmox_vm_qemu.playground_johndoe01, # 608
    proxmox_vm_qemu.playground_johndoe02, # 609
    proxmox_vm_qemu.playground_johndoe03, # 610
  ]

  # A subset, to show that a guest may belong to more than one rule.
  ha_prefer_dev01_guests = [
    proxmox_vm_qemu.playground_test, # 601
    proxmox_vm_qemu.playground_vm01, # 602
  ]
}

# Spread the playground guests across all three nodes with equal weight.
#
# `rule` is the identifier Proxmox knows the rule by.  For a rule that a
# Proxmox 8 -> 9 upgrade created, that is a generated value such as
# "ha-rule-73275e43-c27f" and it differs per cluster; read it off the cluster
# and import, rather than inventing one.  For a rule created here, any name
# works.
resource "proxmox_ha_rule" "ha_bal" {
  rule    = "ha-rule-73275e43-c27f"
  type    = "node-affinity"
  comment = "ha-bal"
  disable = false
  strict  = false

  nodes = {
    "pve-dev01" = 1
    "pve-dev02" = 1
    "pve-dev03" = 1
  }

  # Every guest in ha_bal_guests is added to this rule.  vmid is used directly
  # because each guest above sets it explicitly; for guests that let Proxmox
  # allocate an id, vmid is not written to state and this would silently yield
  # "vm:0" -- use "vm:${element(split("/", vm.id), 2)}" in that case.
  resources = [for vm in local.ha_bal_guests : "vm:${vm.vmid}"]
}

# Prefer pve-dev01 for a couple of guests, without restricting them to it:
# strict = false means the higher priority is a preference, and they can still
# run elsewhere if that node is unavailable.
resource "proxmox_ha_rule" "ha_prefer_dev01" {
  rule    = "ha-prefer-dev01"
  type    = "node-affinity"
  comment = "prefer pve-dev01"
  strict  = false

  nodes = {
    "pve-dev01" = 5
    "pve-dev02" = 1
    "pve-dev03" = 1
  }

  resources = [for vm in local.ha_prefer_dev01_guests : "vm:${vm.vmid}"]
}

# Keep two guests off the same node, so a single node failure cannot take both.
# Resource affinity has no equivalent in the HA groups it replaced.
resource "proxmox_ha_rule" "ha_split_johndoe" {
  rule     = "ha-split-johndoe"
  type     = "resource-affinity"
  comment  = "keep the johndoe guests apart"
  affinity = "negative"

  resources = [
    "vm:${proxmox_vm_qemu.playground_johndoe01.vmid}",
    "vm:${proxmox_vm_qemu.playground_johndoe02.vmid}",
  ]
}
