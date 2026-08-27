# Terraform / OpenTofu provider for Proxmox — personal fork

A fork of [Telmate/terraform-provider-proxmox](https://github.com/Telmate/terraform-provider-proxmox),
branched at **`v3.0.1-rc5`**, exposing resources to provision QEMU VMs and LXC
containers on the [Proxmox virtualization platform](https://pve.proxmox.com/pve-docs/).

> **This is an unsupported personal fork.** It is published so that one set of
> deployments can install it; it carries no support, no compatibility promise
> and no release schedule. If you found it while looking for a Proxmox
> provider, you almost certainly want
> [upstream](https://github.com/Telmate/terraform-provider-proxmox) or
> [bpg/proxmox](https://github.com/bpg/terraform-provider-proxmox) instead.

Licensed MIT, as upstream is. See `LICENSE` for the terms and `NOTICE` for the
fork's provenance.

## Why this fork exists

Our deployments were pinned to upstream `v3.0.1-rc5`, and there was no
practical way to move off it. Upstream shipped a long chain of release
candidates containing breaking schema changes, and the provider defines no
`SchemaVersion` and no `StateUpgraders` anywhere — so nothing migrates existing
state automatically, and every upgrade risks a state file that no longer
matches the schema that wrote it.

Forking at the exact version already in production makes the switch a provider
rename and nothing more: identical schema, identical state. From there,
upstream changes can be adopted deliberately, one at a time, each with a tested
upgrade path for existing state.

Upstream's acceptance tests are not run here as-is: their fixtures set a
top-level `iso` argument that was removed from the schema in February 2024,
274 days before `v3.0.1-rc5` was tagged, so they cannot pass at this or any
later version. New tests are being written instead. See `CLAUDE.md` for the
current state of that work, and `test/acceptance/` for the CI environment that
runs them against real Proxmox 8.4 and 9.2 hosts.

## Getting Started

In order to get started, use [the documentation included in this repository](docs/index.md). The documentation contains
a list of the options for the provider. Moreover, there are some guides available how to combine options and start
specific VMs.

## Quick Start

Follow this [install guide](docs/guides/installation.md) to install the plugin.

## Known Limitations

* `proxmox_vm_qemu`.`disk`.`size` attribute does not match what is displayed in the Proxmox UI.
* Updates to `proxmox_vm_qemu` resources almost always result as a failed task within the Proxmox UI. This appears to be
  harmless and the desired configuration changes do get applied.
* When using the `proxmox_lxc` resource, the provider will crash unless `rootfs` is defined.
* When using the Network Boot mode (PXE), a valid NIC must be defined for the VM, and the boot order must specify network first.

## Contributing

When contributing, please also add documentation to help other users.

### Debugging the provider

Debugging is available for this provider through the Terraform Plugin SDK versions 2.0.0. Therefore, the plugin can be
started with the debugging flag `--debug`.

For example (using [delve](https://github.com/go-delve/delve) as Debugger):

```bash
dlv exec --headless ./terraform-provider-my-provider -- --debug
```

For more information about debugging a provider please
see: [Debugger-Based Debugging](https://www.terraform.io/docs/extend/debugging.html#debugger-based-debugging)

## Useful links

* [Proxmox](https://www.proxmox.com/en/)
* [Proxmox documentation](https://pve.proxmox.com/pve-docs/)
* [Terraform](https://www.terraform.io/)
* [Terraform documentation](https://www.terraform.io/docs/index.html)
* [Recommended ISO builder](https://github.com/Telmate/terraform-ubuntu-proxmox-iso)
