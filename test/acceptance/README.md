# Acceptance test environment

The acceptance tests in `proxmox/resource_vm_qemu_test.go` are not mocked: they
drive a real Proxmox VE API and really create and destroy VMs. This directory
builds a throwaway single node Proxmox VE host inside QEMU so those tests can
run on a laptop or on a GitHub hosted runner, with nothing to pay for and
nothing to clean up afterwards.

## What the tests need

The test fixtures are hardcoded, so the environment has to match them exactly:

| Expectation                          | Where it comes from                                     |
| ------------------------------------ | ------------------------------------------------------- |
| a node called `testproxmox`          | `testAccProxmoxTargetNode` in `resource_vm_qemu_test.go` |
| `local` storage accepting disk images | `/etc/pve/storage.cfg` written at image build time      |
| `local:iso/SpinRite.iso`             | an empty placeholder ISO created at boot                |
| a `vmbr0` bridge                     | a port-less bridge on `10.10.10.1/24`, in `/etc/network/interfaces` |
| `PM_API_URL`, `PM_USER`, `PM_PASS`   | `testAccPreCheck`                                       |

The provider defaults `kvm` to `true` and `power_state` to `running`, so the
guests the tests create are actually started, and they need hardware
virtualisation to be available *inside* the Proxmox VM. See
[Nested virtualisation](#nested-virtualisation) below.

## Layout

```
scripts/build-image.sh   host side: turns a Debian 13 cloud image into a Proxmox VE image
scripts/start.sh         host side: boots that image and waits until the API is usable
scripts/stop.sh          host side: kills the VM and drops its disk overlay
scripts/wait-ready.sh    host side: readiness probe (API + node + fixtures)
scripts/smoke-boot-vm.sh host side: create, boot and destroy a VM over the API
scripts/env.sh           host side: PM_* variables pointing at the local VM
scripts/common.sh        shared configuration, all overridable through PVE_TEST_* variables
guest/provision.sh       runs once inside the VM at build time, installs Proxmox VE
guest/pve-test-hosts.sh  runs on every boot, keeps /etc/hosts pointing at the current IP
guest/pve-test-bootstrap.sh runs on every boot, creates the storage and ISO fixtures
.build/                  downloads, the built image, console logs (git ignored)
```

## Running it locally

Requirements: `qemu-system-x86_64`, `qemu-img`, `xorriso`, `curl`, a writable
`/dev/kvm`, ~10GB of disk and 8GB of spare RAM.

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils xorriso

make testenv-build          # ~10 min and ~2GB of downloads, only needed once
PVE_TEST_PVE_VERSION=8 make testenv-build   # and again for the Proxmox 8 baseline
make acctest-local          # boots the VM if needed, then runs every acceptance test
make acctest-local TESTARGS='-v -run=TestAccProxmoxVmQemu_BasicCreate'
make testenv-down           # throw the VM away
```

`make acctest-local` deliberately does not depend on the `build` target, because
`build` depends on `clean`, which is `git clean -f -d`.

To point the normal `make acctest` at the VM instead:

```bash
source test/acceptance/scripts/env.sh
make acctest TESTARGS='-v'
```

The Proxmox web UI is on <https://127.0.0.1:8006> (`root` / `proxmox-acctest`),
and `ssh -p 2222 root@127.0.0.1` gets you a shell on the node. Both are useful
when a test fails and you want to look at what it left behind.

## Proxmox 8 vs Proxmox 9

`PVE_TEST_PVE_VERSION` selects the major version: `9` (Debian 13 trixie,
the default) or `8` (Debian 12 bookworm). The two images, overlays, pidfiles
and console logs are named per version, so both can be built and even run at
the same time.

This is the point of the whole exercise: production is on Proxmox 8 and moving
to Proxmox 9, and the provider version pinned in production predates Proxmox 9
by nine months. Running the same test suite against both tells us what
actually breaks, rather than guessing. The CI workflow runs both by default.

## Running it in CI

`.github/workflows/acceptance-test.yml` does the same thing on `ubuntu-latest`,
as a matrix over **Proxmox VE 8.4** and **9.2**. It is `workflow_dispatch` plus
a nightly schedule on purpose: acceptance tests take a long time and should not
run automatically on pull requests, least of all from forks.

The nightly run exists mainly to keep the cached images alive, since GitHub
evicts caches unused for 7 days. Note that on a **public** repository GitHub
disables scheduled workflows after 60 days without repository activity; if the
fork goes quiet, the schedule stops and the next run rebuilds from scratch.

By default it runs only the boot test
(`-run=TestAccProxmoxVmQemu_BasicCreate`), preceded by a hypervisor level check
that does not involve a CLI at all.

> The upstream acceptance tests do not pass, and have not since long before
> `v3.0.1-rc5`: their fixtures set a top level `iso` argument that was removed
> from the schema in February 2024. Point `testargs` at new tests as they are
> written. The hypervisor level check below is unaffected by any of that.


```
Boot a VM (hypervisor level)     scripts/smoke-boot-vm.sh, straight at the API
Boot a VM (through the provider) make acctest -run=TestAccProxmoxVmQemu_BasicCreate
```

If the first passes and the second fails, the problem is the provider. If the
first fails, nothing else is worth looking at.

### Image reuse

Building Proxmox takes about ten minutes, so the image is cached and every
later run just boots it.

* The cache is keyed on the contents of `guest/*.sh`, `scripts/common.sh` and
  `scripts/build-image.sh`, per Proxmox version. Editing any of those rebuilds.
* Restore and save are **separate steps** (`actions/cache/restore` and
  `actions/cache/save` with `if: always()`). `actions/cache` alone only saves
  in its post step when the job succeeded, which would mean a failing test run
  rebuilds Proxmox from scratch every time. That is the common case while the
  fork is being sorted out, so it matters.
* A rebuild triggered with `force_rebuild` does **not** overwrite the cache
  entry: the key already exists. Bump `IMAGE_CACHE_EPOCH` in the workflow to
  cut everyone over to a fresh image.
* GitHub evicts caches unused for **7 days**, and evicts least recently used
  entries once a repository exceeds **10GB**. The nightly run keeps the current
  pair warm.
* **Prune after changing the provisioning.** Each image is 2-3GB and the key is
  a content hash of `guest/*.sh`, `scripts/common.sh` and
  `scripts/build-image.sh`, so every edit to those orphans the previous pair,
  ~5GB at a time. A few rounds of changes is enough to blow through the 10GB
  limit and start evicting the images you wanted to keep. See CLAUDE.md for the
  `gh api` commands to list and delete stale entries.
* Caches are scoped per branch: a branch can read caches from itself, its base
  branch and the default branch. Build the images once **on the default
  branch** so every feature branch inherits them instead of building its own.
* If the 7 day eviction ever becomes annoying, publish the images as GHCR
  artifacts or release assets instead; neither expires.

### Versions

`8.4` is the final Proxmox VE 8 release and `9.2` is current, so the
`bookworm` and `trixie` no-subscription repositories serve exactly those. That
is checked rather than pinned: `wait-ready.sh` and `smoke-boot-vm.sh` report
the running version and warn loudly if it is not what
`PVE_TEST_EXPECT_VERSION` says, so an upstream point release shows up in the
log instead of silently changing what is being tested.

## Nested virtualisation

This is the one thing that is not fully under our control.

There are three levels involved: the GitHub runner (itself a VM), the Proxmox
VM this directory builds, and the guests the acceptance tests create inside it.
The second level needs `/dev/kvm` on the runner, which GitHub hosted Ubuntu
runners do provide. The third level needs the runner to pass virtualisation
extensions down, which is why `start.sh` uses `-cpu host` and the image sets
`nested=1` for `kvm-intel`/`kvm-amd`.

If that last hop does not work on a given runner, `qm start` fails with:

```
KVM virtualisation configured, but not available. Either disable in VM configuration or enable in BIOS.
```

Two ways out:

* add `kvm = false` to the test fixtures in `resource_vm_qemu_test.go` (the
  guests then run under TCG emulation, which is fine because they never boot
  anything real), or
* point the tests at real hardware instead, see below.

`PVE_TEST_ACCEL=tcg` makes the *Proxmox VM itself* run without KVM. It works,
but it is slow enough that it is only useful for debugging the scripts.

## Pointing the tests at a real Proxmox host

Nothing in the test suite is tied to this VM. To run against real hardware, on
a self hosted runner or from your own machine, just set the variables and skip
everything above:

```bash
export PM_API_URL=https://pve.example.com:8006/api2/json
export PM_USER=root@pam
export PM_PASS=...
export PM_TLS_INSECURE=true
make acctest TESTARGS='-v'
```

To drive the tests with OpenTofu rather than Terraform, as CI does, also set:

```bash
export TF_ACC_TERRAFORM_PATH="$(command -v tofu)"
export TF_ACC_PROVIDER_HOST=registry.opentofu.org
export TF_ACC_PROVIDER_NAMESPACE=hashicorp
```

The host and namespace are not cosmetic: the SDK keys `TF_REATTACH_PROVIDERS`
on `host/namespace/name`, and `tofu` resolves a bare `proxmox` provider to
`registry.opentofu.org/hashicorp/proxmox`. Get them wrong and `tofu` tries to
download the provider instead of using the one the test is running in-process.

The host still has to satisfy the table at the top of this file: a node named
`testproxmox`, a `local` storage that accepts images, `local:iso/SpinRite.iso`
and a `vmbr0` bridge. `guest/pve-test-bootstrap.sh` can be run as is on such a
host to create the storage and ISO parts.

## Configuration

Every setting in `scripts/common.sh` can be overridden from the environment:

| Variable                    | Default            | Meaning                              |
| --------------------------- | ------------------ | ------------------------------------ |
| `PVE_TEST_PVE_VERSION`      | `9`                | build Proxmox VE `8` or `9`          |
| `PVE_TEST_EXPECT_VERSION`   | `8.4` / `9.2`      | version to warn about if not matched |
| `PVE_TEST_SMOKE_VMID`       | `9001`             | VMID used by the boot smoke test     |
| `PVE_TEST_NODE_NAME`        | `testproxmox`      | must match the test fixtures         |
| `PVE_TEST_ROOT_PASSWORD`    | `proxmox-acctest`  | root password of the throwaway VM    |
| `PVE_TEST_API_PORT`         | `8006`             | forwarded API port on the host       |
| `PVE_TEST_SSH_PORT`         | `2222`             | forwarded SSH port on the host       |
| `PVE_TEST_MEMORY`           | `8192`             | RAM for the Proxmox VM, in MB        |
| `PVE_TEST_CPUS`             | `3`                | vCPUs for the Proxmox VM             |
| `PVE_TEST_DISK`             | `32G`              | disk size of the Proxmox VM          |
| `PVE_TEST_ACCEL`            | `kvm`              | set to `tcg` to run without KVM      |
| `PVE_TEST_IMAGE`            | `.build/proxmox-ve-test.qcow2` | path of the built image  |
| `PVE_TEST_FORCE_REBUILD`    | `0`                | rebuild even if the image exists     |
| `PVE_TEST_DEBIAN_IMAGE_URL` | per `PVE_VERSION`  | base image to build from             |
| `PVE_TEST_KEYRING_URL`      | per `PVE_VERSION`  | Proxmox release keyring              |

## Troubleshooting

* **`Errors were encountered while processing: grub-pc`** during the build.
  Installing `proxmox-ve` pulls a kernel, and grub-pc's postinst asks which
  disk to install to, which is fatal non-interactively. `provision.sh`
  preseeds `grub-pc/install_devices` from the detected root disk.
* **The build times out.** `.build/build-console.log` is the VM's serial
  console, including all of cloud-init's output. Provisioning failures print
  `PVE_BUILD_FAIL` there.
* **`bridge 'vmbr0' does not exist`** when a VM starts. The stanza lives in
  `/etc/network/interfaces`, not `interfaces.d/`, because the Debian cloud
  image does not reliably source that directory. It is also added to
  `/etc/network/interfaces.new` when the ifupdown2 postinst has created one,
  since PVE applies that file on the next boot and would otherwise discard the
  bridge. The readiness probe asks the node for its interface list, so a
  missing bridge is reported before any test runs.
* **`/etc/pve is not mounted`** during the build. pve-cluster failed to
  start. Note the build does not wait for a file *inside* `/etc/pve`: on a
  Debian based install PVE writes no default `storage.cfg` until it has been
  through a boot, so the bootstrap writes that config itself.
* **`node is online but the fixtures are missing`.** The image was built
  without them. The fixtures are baked in at build time now, so rebuild:
  `PVE_TEST_FORCE_REBUILD=1 make testenv-build`, or bump `IMAGE_CACHE_EPOCH`
  in the workflow so CI stops restoring the stale image.
* **`No space left on device` while compacting.** The uncompressed image plus
  the work image it is converted from need ~15GB. In CI the build runs on
  `/mnt`; locally, point `PVE_TEST_BUILD_DIR` somewhere with room.
* **`wait-ready.sh` times out.** `.build/run-console.log` is the serial console
  of the running VM. The probe reports which of its three checks was failing
  (API, node status, fixtures).
* **Every test fails at provider configure time on Proxmox 9** with
  `permissions ... are not sufficient ... [VM.Monitor]`. That is expected on a
  provider older than 3.0.2-rc04: Proxmox 9 removed the `VM.Monitor`
  privilege. See CLAUDE.md.
* **Tests fail but the API works.** `acctest.log`, written two levels above the
  `proxmox` package, has the full provider and Proxmox API traffic.
