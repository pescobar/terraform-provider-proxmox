# CLAUDE.md

Working notes for this fork of
[Telmate/terraform-provider-proxmox](https://github.com/telmate/terraform-provider-proxmox).

## The plan

Production runs **Telmate/proxmox `v3.0.1-rc5`** (tagged 2024-11-24) with
**OpenTofu**, against a **Proxmox VE 8** cluster that is going to be upgraded
to **Proxmox VE 9**.

Upstream is not a viable upgrade path: between `v3.0.1-rc5` and the current
`v3.0.2-rc09` there are 191 commits touching `proxmox/` across 171 files
(+8359/-2580) and a string of breaking schema changes spread over 21 months, in
a chain of release candidates. Upgrading through that is the problem we are
trying to avoid, not something to solve on the way.

So the plan is deliberately narrow:

1. **Fork at `v3.0.1-rc5` exactly**, not at upstream HEAD. Same code,
   different provider address.
2. Move production state onto the fork. Because the code is identical, this is
   a provider rename and nothing else.
3. Only then, backport from upstream selectively, on our own schedule, with a
   real upgrade path per change.

What we are buying is control over *when* breaking changes land, not new
features.

## Status

### Done: the baseline branch (`fork-base`, from `v3.0.1-rc5`)

Branched from the tag, with the CI tooling carried over from the HEAD-based
branch. Changes on top of rc5, all of them mechanical:

* Go module renamed `github.com/Telmate/terraform-provider-proxmox/v2` ->
  `github.com/pescobar/terraform-provider-proxmox`, 23 references across 13
  files. Dropping `/v2` also fixes an upstream inconsistency: the module
  carried a `/v2` suffix while the tags said `v3.x`.
* `main.go` debug registry address -> `registry.opentofu.org/pescobar/proxmox`.
* `go.yml` un-parked, targeting `main`, actions on Node 24 majors.
* `release.yml` un-parked, ready for `GPG_PRIVATE_KEY` / `PASSPHRASE`.
* LICENSE keeps upstream's MIT notice verbatim and adds ours, as MIT requires.
* README explains what this fork is and why it exists.
* The acceptance workflow defaults to Proxmox 8.4 only, and its default
  `testargs` matches nothing, because the inherited tests cannot pass.

**Verified locally and in CI:** `go mod download`, `go vet`, `go build`,
`go test -race` and `gofmt` all pass on the renamed module. Go 1.22 is
installed on the dev box (`apt install golang-go`, aarch64), plus
`staticcheck` in `~/go/bin`.

Two things the rename shook out, both fixed:

* **gofmt.** Import blocks were sorted for `github.com/Telmate/...`; the new
  path sorts differently, so nine files became unformatted. `go.yml` does not
  check formatting, so CI would not have caught it. Consider adding a `fmt`
  job.
* **`make test_unit` does not exist at rc5.** That target arrived upstream
  later; rc5's Makefile has `test`. HEAD's `go.yml` called the newer name and
  the job failed instantly. Anything else inherited from HEAD's workflows
  should be checked against rc5's Makefile the same way.

**Known inherited debt: 23 `staticcheck` SA1019 findings**, all of them the
deprecated non-Context CRUD fields (`Create` rather than `CreateContext`) in
`resource_lxc.go`, `resource_pool.go`, `resource_storage_iso.go`,
`data_ha_group.go` and others. They are pre-existing in rc5, not caused by the
fork. The `staticcheck` job is `continue-on-error: true` so the signal stays
visible without gating every build. **Do not fix them in the drop-in version**:
moving to `CreateContext` changes cancellation behaviour, so it belongs in a
later release with its own testing, as part of the "align with Go and
Terraform practices" pass.

The Makefile derives its version from `git describe --tags`; CI checkouts are
shallow and tagless, so it evaluated `$((<sha>+1))` and bash printed
`value too great for base` on every run. `fetch-depth: 0` fixes it.

Version numbering: publish `0.9.x` for the migration rehearsal, then `1.0.0`
from the same commit as the last `0.9.x` once the rehearsal passes. Do **not**
reuse upstream's `v3.0.1-rc5` string: `-rc5` is a prerelease, which ordinary
version constraints refuse to match, and the same string would mean two
different artifacts.

### Blocker found: `v3.0.1-rc5` cannot talk to Proxmox VE 9 at all

Proxmox 9 **removed the `VM.Monitor` privilege** (it was replaced by
`Sys.Audit` for monitor access, and `VM.GuestAgent` for agent operations).
`v3.0.1-rc5` has the minimum permission list hardcoded in
`proxmox/provider.go` (~line 234) and it includes `VM.Monitor`. When a required
privilege is missing the provider does not warn, it fails configuration:

```
permissions for user/token root@pam are not sufficient, please provide also the
following permissions that are missing: [VM.Monitor]
```

This hits **every user including `root@pam`**, because on Proxmox 9 the
privilege does not exist and therefore cannot be granted. Upstream fixed it in
`v3.0.2-rc04` by deleting one line
(`e5c9963`), and separately added `Pool.Audit`
(`9ae1698`). Those are the *only* two Proxmox-9-specific commits in the entire
range between rc5 and HEAD.

**First backport, and it is one line:** remove `"VM.Monitor"` from
`minimumPermissions`. Worth also backporting the later
`pm_minimum_permission_check` / `pm_minimum_permission_list` provider
arguments, which exist at HEAD but not at rc5, so a future privilege rename
becomes configuration rather than a code change.

Whether anything *else* breaks on Proxmox 9 is unknown, and that is what the
test environment below is for.

### Done: acceptance test environment (2026-08-27)

The acceptance tests are not mocked, they drive a real Proxmox VE API.
`test/acceptance/` builds a throwaway single node Proxmox VE host inside QEMU,
for **Proxmox 8.4 or 9.2**, so the same suite can be run against the version
production is on and the version it is moving to.

```
test/acceptance/scripts/build-image.sh    Debian cloud image -> Proxmox VE qcow2
test/acceptance/scripts/start.sh          boot it on a fresh overlay, wait for readiness
test/acceptance/scripts/stop.sh           kill it, drop the overlay
test/acceptance/scripts/wait-ready.sh     probe: API auth -> node online -> fixtures
test/acceptance/scripts/smoke-boot-vm.sh  create, boot and destroy a VM over the API
test/acceptance/scripts/env.sh            PM_* variables for the local VM
test/acceptance/scripts/state-profile.sh  profile a real state file (see below)
test/acceptance/scripts/common.sh         all settings, overridable via PVE_TEST_*
test/acceptance/guest/                    scripts that run inside the VM
test/acceptance/README.md                 full documentation
.github/workflows/acceptance-test.yml     matrix over 8.4 and 9.2, images cached
```

```bash
make testenv-build                            # Proxmox 9.2 image
PVE_TEST_PVE_VERSION=8 make testenv-build     # Proxmox 8.4 image
make acctest-local TESTARGS='-v'
```

**Current scope is deliberately one question: can a VM be booted in CI?** The
workflow runs a hypervisor level boot test (`smoke-boot-vm.sh`, straight at the
API, no terraform) followed by a single provider level one
(`TestAccProxmoxVmQemu_BasicCreate`). Widening to the full suite is a
`testargs` input away, once booting is proven.

**It applies unchanged to the rc5 fork:** `proxmox/resource_vm_qemu_test.go`
and `proxmox/provider_test.go` are byte-identical between `v3.0.1-rc5` and
HEAD, so the environment works on the rc5 branch as-is.

**The infrastructure question is settled (run 33081184369, 2026-08-27).**
GitHub hosted runners boot VMs three levels deep, on both target versions:

```
Proxmox VE 8.4.21:  PASS: boots VMs with hardware acceleration (kvm=1)
Proxmox VE 9.2.11:  PASS: boots VMs with hardware acceleration (kvm=1)
```

`kvm=1`, not the TCG fallback, so the acceptance tests need no `kvm = false`
workaround. Runners provide `/dev/kvm`, AMD `svm` and `kvm_amd nested=1`.
Images build, cache, restore and boot on both versions; the whole loop works
on standard runners, with no self hosted runner required.

Seven rounds of environment bugs were fixed getting there, each a different
layer: `grub-pc` prompting for an install disk (Debian 13 only), a compressed
qcow2 making first boot take ten minutes, the runner's root volume being too
small, fixtures never created because their unit was ordered behind
`pveproxy.service` (whose start job never completes), waiting for a
`storage.cfg` that PVE does not write until first boot, `set -o pipefail`
killing the boot test on a `grep` that matched nothing, and `vmbr0` living in
an `interfaces.d/` nobody sources. The pattern worth keeping: every fixture is
now verified inside the guest before the image is allowed into the cache.

**The upstream acceptance tests are dead code.** The provider level step fails
on the fixtures, not the environment:

```
Error: Unsupported argument
   6:   iso = "local:iso/SpinRite.iso"
An argument named "iso" is not expected here.
```

The top level `iso` argument was removed in `2808e32` ("Remove `ISO` setting
and unlock `ide2`", 2024-02-23), which is an ancestor of `v3.0.1-rc5`, tagged
274 days later. So these fixtures cannot pass at HEAD *or* at rc5, and the
repo ships no acceptance workflow. Upstream has not run this suite in over two
years. Note this revises an earlier observation: the test files being byte
identical between rc5 and HEAD means identically *stale*, not portable.

**Decision: write new acceptance tests in the fork.** The old ones are a
reference for what to cover, not something to port. Fixing them would preserve
two year old assumptions nobody has validated.

**Verification status.** The host side was smoke tested end to end with stubbed
`qemu`/`curl` for both Proxmox versions, including all four outcomes of the
boot test (KVM works / only TCG works / version drift / cannot boot). The
workflow is actionlint clean. The guest side (the actual Proxmox install) has
**not** been run yet: no `/dev/kvm` and no access to `download.proxmox.com` on
the machine it was written on. The first CI run is the real test.

**Known risk: three levels of virtualisation.** The provider defaults
`kvm = true` and `power_state = running`, so the tests really boot guests,
inside the Proxmox VM, inside the runner. `smoke-boot-vm.sh` exists to tell
that apart from everything else: it retries with `kvm=0` and reports which
mode worked, so a failure says whether the runner cannot nest or the
environment is broken.

**Image reuse.** Building Proxmox takes ~10 minutes; after the first run the
image comes from the Actions cache and the job just boots it (~6 minutes for
the whole matrix instead of ~20). Restore and save are separate steps with
`if: always()`, because `actions/cache` does not save when a job fails, and
failing runs are expected here.

**Watch the cache total: the images are big and the limit is 10GB.** Each
image is 2-3GB, so one pair fills half the repository's cache allowance. The
cache key is a content hash of `guest/*.sh`, `scripts/common.sh` and
`scripts/build-image.sh`, so **every edit to any of those mints a new key and
orphans the previous pair, ~5GB at a time**. Nothing reclaims the old entries
automatically until GitHub starts evicting, and it evicts least-recently-used,
which can take the images with it.

This bit us on 2026-08-27: four images, 11.27GB, over the limit and evicting.
Check and prune after a run of provisioning changes:

```bash
gh api repos/<owner>/<repo>/actions/cache/usage
gh api repos/<owner>/<repo>/actions/caches --jq \
    '.actions_caches[] | "\(.id) \(.size_in_bytes/1e9|floor)GB \(.key)"'
gh api -X DELETE repos/<owner>/<repo>/actions/caches/<id>
```

Entries whose hash suffix does not match the current scripts can never be hit
again; they are only crowding the limit. To find the current suffix, hash the
same files the workflow does, in the same order.

### Done: acceptance tests for the fork (2026-08-30)

Written from scratch against the rc5 schema. The inherited upstream tests are
not a base to build on: they still configure a top level `iso` argument that
was removed in `2808e32`, an ancestor of rc5. Everything the fork adds is
prefixed `fork` / `TestAccFork` so the delta against upstream stays legible.

```
proxmox/fork_acctest_test.go   fixtures, provider plumbing, check funcs, HCL builder
proxmox/fork_vm_qemu_test.go   the VM tests
proxmox/fork_pool_test.go      proxmox_pool
proxmox/fork_upgrade_test.go   provider version upgrade tests
```

**They land in stages, one push at a time.** The environment has never run a
provider level test, so widening the suite and debugging the environment at the
same time would make every failure ambiguous. The first push carries the
scaffolding and `TestAccForkVmQemu_Minimal` alone, with the workflow's default
`testargs` pointed at exactly that test. Each later push adds a group and
widens the default:

| Stage | Adds | Default `testargs` |
| --- | --- | --- |
| 1 | scaffolding, `_Minimal` | `-run=TestAccForkVmQemu_Minimal` |
| 2 | `_FullShape`, `_Import`, `_UpdateInPlace`, `_TagsAreOrderInsensitive`, `_StoppedState` | `-run=TestAccForkVmQemu_` |
| 3 | `TestAccForkPool_Basic` | `-run=TestAccFork(VmQemu\|Pool)_` |
| 4 | the upgrade tests | unchanged; opt in with `-run=TestAccForkUpgrade` |

Do not skip ahead: a green stage is what makes the next one's failures
readable.

**The suite is deliberately small, and grows on demand.** It covers the
features in routine use, not the schema surface. Adding a test is cheap;
maintaining tests for paths nobody uses is not. Deferred on purpose, with the
reason:

* **HA (`hastate`, `hagroup`)** -- set on 69 of 70 production VMs, so this is
  the largest known gap. Left out by choice, not oversight. A single node
  `pvecm create` cluster would make `ha-manager` answer, if it is ever wanted.
* **`protection = true`** -- blocks destroy, so any test using it needs a final
  step turning it off or the framework's cleanup wedges the VM.
* **Multi-node / `target_nodes`, PCI and USB passthrough, `efidisk` / OVMF,
  `args`, cloud-init, clone-from-template** -- none of these appear in the
  state we run, so there is nothing to regress yet.
* **`format = "raw"`** -- 7 of 120 production disks. The test image's `local`
  is a `dir` storage, so qcow2 is the faithful default; raw would want an
  LVM-thin storage adding to the image.

#### The trap that shaped every test config

`define_connection_info` defaults to **`true`**, and `initConnInfo`
(`resource_vm_qemu.go:1557`) only returns early when it is `false`. With
`agent = 1` -- which every production VM sets -- a config that leaves the
default in place makes the provider block waiting for a guest agent that a PXE
booted VM with no OS never starts, for the whole 20 minute create timeout.
Production sets it `false` on all 70 VMs, so the tests do too, explicitly.

#### The upgrade tests, and why they work

`helper/resource` builds `TF_REATTACH_PROVIDERS` keyed as `host/namespace/name`,
taking the first two from `TF_ACC_PROVIDER_HOST` and `TF_ACC_PROVIDER_NAMESPACE`
(SDK `helper/resource/plugin.go`, `getProviderAddr`). Setting those to the
address a state file already records makes the in-process provider answer for
that address. So one step can create resources with a released provider pulled
from the registry, and the next step reads that state with the working tree's
code. Providers are declared per step: the SDK rejects a case that sets them at
both the TestCase and TestStep level.

* `TestAccForkUpgrade_FromUpstreamRc5` -- upstream `telmate/proxmox` 3.0.1-rc5
  creates the VM, the fork adopts the state. An empty plan is the acceptance
  criterion for moving production onto the fork; the third step also requires
  the vmid to be unchanged, because a recreate would rebuild the fleet.
* `TestAccForkUpgrade_FromPreviousRelease` -- the same against the fork's last
  published version. Skips unless `PVE_TEST_PREVIOUS_VERSION` is set. **This is
  the guarantee upstream never offered, so it is the one never to break**: any
  change needing `SchemaVersion` + `StateUpgraders` fails here first.

Unverified: `VersionConstraint: "3.0.1-rc5"` is a prerelease. An exact pin
normally resolves, but it has not been run. Overridable with
`PVE_TEST_UPSTREAM_VERSION`; the fallback is a filesystem mirror. These are
also the only tests needing the network beyond the local Proxmox VM.

#### Fixtures

Generic names, all overridable so the suite can run against a real cluster:
`PVE_TEST_NODE` (`testproxmox`), `PVE_TEST_STORAGE` (`local`),
`PVE_TEST_BRIDGE` (`vmbr0`), `PVE_TEST_BRIDGE2` (`vmbr1`), `PVE_TEST_ISO`
(`local:iso/SpinRite.iso`).

`vmbr1` is new: 55 of 70 production VMs have two or more interfaces, so
multi-interface VMs are the common case, not an edge case. It is addressless,
verified at build time so a broken image never reaches the cache, and probed by
`wait-ready.sh` alongside `vmbr0`. **`IMAGE_CACHE_EPOCH` went 2 -> 3** for it;
the provisioning change re-keys the cache anyway, so prune the orphaned pair.

The workflow's default `testargs` tracks the stage table above. The upgrade
tests are always opt in, with `-run=TestAccForkUpgrade`: they are the only ones
that reach the network beyond the local Proxmox VM.

### Done: profiling the production state (2026-08-30)

`test/acceptance/scripts/state-profile.sh` reports how a real state file uses
the provider, so tests aim at the schema actually in production rather than at
the whole surface. It filters to `proxmox_*`, never prints secrets, and shows
identifying values as set/unset unless given `--show-values`.

```bash
./test/acceptance/scripts/state-profile.sh ~/tmp/tofu-int.tfstate
```

What it found, and what the tests were built from:

* **The fleet is PXE booted, with MAAS installing the OS.** `pxe` on 67 of 70,
  and no cloud-init, no `clone`, no template anywhere. The provider's job ends
  once the VM exists and runs. This removes most of the fixture cost that a
  clone-based workflow would have needed.
* **Boot disk is `virtio0`, not scsi** (`boot = "order=virtio0;net0"`).
  `scsihw = virtio-scsi-single` is set on all 70 but unused, there being no
  scsi disks.
* **`hotplug = "cpu,network,disk,usb"`** -- not the schema default
  (`network,disk,usb`), so it is a deliberate setting and is asserted.
* Structured `disks` block, never the legacy flat `disk`. `cpu_type`, never the
  deprecated `cpu`. Both are the non-deprecated spellings, so no schema
  migration debt is hiding in the state.
* **No VLAN tags at all** (149 interfaces, every `tag` 0), so a VLAN aware
  bridge is not needed in the image.
* `format = qcow2` on 113 of 120 disks, against a schema default of `raw`, so
  the configs always set it explicitly.
* Two provider aliases, `pveint` and `pveusr`, on one address -- two clusters
  (`pve-int0*` and `pve-usr0*` nodes). `state replace-provider` keys on the
  address, so one run covers both.
* **Tags are safe.** `Internal/pxapi/guest/tags/tags.go:47` sorts and
  deduplicates both sides in a `DiffSuppressFunc`, so unsorted tag lists do not
  drift. Worth a regression test precisely because a future backport could
  silently drop it.

Two things to settle before the migration rehearsal, both from section 8:

* **`ldap_main`, `logserver` and `mirror` have `vmid` absent entirely** -- not
  zero, absent -- and are the same three lacking `pxe`. This is **not** stale
  state: rc5 never calls `d.Set("vmid", ...)` anywhere. `vmid` is
  Optional+Computed+ForceNew but is only ever read *from* the configuration
  (`resource_vm_qemu.go:794`), so a config that does not set it explicitly
  leaves it absent from state for good. The other 67 have it because their
  configs name it. Confirmed by `TestAccForkVmQemu_Minimal`, which failed on
  exactly this the first time it ran.

  Worth leaving alone in the drop-in release. Writing `vmid` back would change
  what lands in state, which is the one thing the migration must not do; it
  belongs in a later release with its own `SchemaVersion` if it is wanted at
  all. Tests assert on the resource id, which carries the real vmid, instead.
* **`proxmox_vm_qemu.testvms` has 2 instances**, so there is a `count` /
  `for_each` resource with indexed addresses for the state rewrite to handle.

### Next

1. Run the new suite for the first time, against both Proxmox versions:
   `make acctest-local TESTARGS='-run=TestAccForkVmQemu_Minimal -v'` locally,
   then the workflow. The `vmbr1` addition means the images rebuild once.
2. Backport the one line that removes `VM.Monitor` from `minimumPermissions`,
   without which rc5 cannot talk to Proxmox 9 at all. Consider also
   backporting `pm_minimum_permission_check` / `pm_minimum_permission_list`.
   `TestAccForkPool_Basic` is the test that covers the related `Pool.Audit`.
3. Confirm `TestAccForkUpgrade_FromUpstreamRc5` can resolve the `3.0.1-rc5`
   prerelease from the registry; fall back to a filesystem mirror if not.
4. Look at the three VMs with no `vmid`, and at the `count` based resource,
   before rehearsing anything.
5. Rehearse the state migration on a copy of a production state file, and
   confirm `tofu plan` is empty.
6. Add tests as the need appears, not in advance. HA is the biggest known gap.

## Provider migration (Telmate -> fork), with OpenTofu

Supported, and forking at rc5 makes it as safe as it can be: the schema is
identical, so nothing but the provider address changes.

**A. New namespace, rewrite state.** State records each resource's provider as
a fully qualified address, e.g.
`provider["registry.opentofu.org/telmate/proxmox"]`. Change `source` in
`required_providers`, then:

```bash
tofu state pull > backup.tfstate         # the command backs up too, but still
tofu state replace-provider \
    registry.opentofu.org/telmate/proxmox \
    registry.opentofu.org/<namespace>/proxmox
rm .terraform.lock.hcl && tofu init -upgrade
tofu plan                                # must be empty
```

Check the exact FROM address inside the state file first: state written by
Terraform says `registry.terraform.io/...`, state written by OpenTofu says
`registry.opentofu.org/...`.

**B. Keep the address, swap the binary.** Leave `source` as `telmate/proxmox`
and serve the fork through a filesystem or network mirror
(`provider_installation` in the CLI config). No state rewrite at all, but the
fork cannot be published to a registry under someone else's namespace, so this
is internal distribution only. Reasonable as a first step, and it keeps
option A available later.

Either way an empty `tofu plan` after the switch is the acceptance criterion.

## Facts about the codebase (verified at `ab9dbfa`, not assumed)

* **No state versioning anywhere.** No `SchemaVersion`, no `StateUpgraders`, no
  `MigrateState` in the entire provider, at rc5 or at HEAD. Every resource is
  schema version 0. That is *why* upstream upgrades are so painful: breaking
  schema changes shipped with no migration path. Any breaking change we make in
  the fork must bring its own `SchemaVersion` + `StateUpgraders`, which is the
  main thing the fork can do better than upstream.
* The acceptance tests hardcode the node name `testproxmox`
  (`testAccProxmoxTargetNode`) and expect `local` storage to accept disk
  images, a `local:iso/SpinRite.iso` and a `vmbr0` bridge.
* `main.go` hardcodes `registry.terraform.io/telmate/proxmox` as the default
  `-registry` flag for debug mode; the fork needs to change it.
* `make clean` is `git clean -f -d`, and `build` depends on it. Untracked files
  are deleted by `make build` / `make acctest`. Commit before running those.
  `make acctest-local` deliberately avoids that chain.
* Release tooling already exists: `.goreleaser.yml` plus
  `.github/workflows/release.yml`, GPG signed, on `v*` tags. That is most of
  what a registry publication needs.
* **The acceptance harness runs under OpenTofu, not Terraform.** CI uses
  `opentofu/setup-opentofu@v2` with `provider_acceptance_tests: true`, which
  exports `TF_ACC`, `TF_ACC_TERRAFORM_PATH`, `TF_ACC_PROVIDER_HOST` and
  `TF_ACC_PROVIDER_NAMESPACE`. SDK v2.40.1 honours all four:
  `internal/plugintest` uses `TF_ACC_TERRAFORM_PATH` as an exact CLI source,
  and `helper/resource` keys `TF_REATTACH_PROVIDERS` as `host/namespace/name`,
  defaulting to `registry.terraform.io`. That default is why the host matters:
  `tofu` resolves a bare `proxmox` provider to
  `registry.opentofu.org/hashicorp/proxmox`, so without the override it would
  try to download the provider instead of using the in-process one.
  To run the same tests under Terraform, swap the step for
  `hashicorp/setup-terraform` with `terraform_wrapper: false`.

## Upstream automation is parked, not deleted

`.github/workflows/` contains **only** `acceptance-test.yml`. Everything
inherited from upstream lives in `.github/disabled-upstream/`, which GitHub
does not scan: `go.yml`, `release.yml`, `manage_issues.yml` and
`dependabot.yml`. See the README there for what each one did and why it is off.

This is deliberate. `release.yml` triggers on `v*` tags and would fire once per
upstream tag (51 of them) and fail without the GPG secrets; `dependabot.yml`
would start moving dependencies, which is precisely what the fork exists to
control. `go.yml` (build, vet, staticcheck, unit tests) is the one worth
adopting, once the fork's branch naming is settled.

The nightly schedule on `acceptance-test.yml` is enabled. It mainly keeps the
cached images from being evicted after 7 days of disuse: a run that restores
them takes ~6 minutes of runner time for the whole matrix, one that rebuilds
both takes ~20.

Pull requests run the workflow too, gated by the repository setting
**Settings -> Actions -> General -> "Require approval for first-time
contributors"**, which is a repository setting rather than anything in the
workflow file, and applies to fork pull requests on a public repository. Fork
PRs also get a read-only token and no secrets; this workflow needs neither.
A `concurrency` group cancels a superseded PR run rather than booting two sets
of VMs, while scheduled and manual runs are never cancelled.

**This repository is intended to be made public once it is ready.** Two things
change when it is: GitHub-hosted runner minutes stop counting against a quota
entirely, and scheduled workflows get disabled automatically after 60 days
without repository activity. Nothing in the workflow needs to change for the
switch. The `PM_PASS` in it is deliberate, not a leaked secret: it is the root
password of a throwaway VM that only ever listens on the runner's loopback.

## Conventions

* Fork base is `v3.0.1-rc5`. Every deviation from it should be a small, single
  purpose commit that says what it backports and why, so the delta stays
  auditable.
* Breaking schema changes require `SchemaVersion` + `StateUpgraders`. No
  exceptions; this is the reason the fork exists.
* New tooling lives in `test/`, not in `proxmox/`, to keep the diff against
  upstream legible. Go acceptance tests are the exception, since they have to
  be in `package proxmox`; those are named `fork_*_test.go` instead.
* Acceptance tests start simple and grow on demand. Cover what is actually
  used, add a test when a feature starts being used or a bug needs pinning,
  and write down what was deferred and why rather than leaving it implied.
* `test/acceptance/.build/` is git ignored: downloads, images and console logs.
