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
* The acceptance workflow defaults to Proxmox 8.4 only. Its default `testargs`
  now runs the fork's own suite; it used to match nothing, because the
  inherited tests could not pass.

**Verified locally and in CI:** `go mod download`, `go vet`, `go build`,
`go test -race` and `gofmt` all pass on the renamed module.

**Dev box toolchain, aligned with CI (2026-08-31).** The box has Debian's
`golang-1.22-go` at `/usr/lib/go-1.22`, which is too old to install a
staticcheck that detects the SA1019 findings, so local lint runs were quietly
reporting a clean tree. Fixed without root or apt, using Go's own toolchain
mechanism:

```bash
go env -w GOTOOLCHAIN=go1.26.7          # the version CI's `1.26` resolves to
go install honnef.co/go/tools/cmd/staticcheck@v0.8.1
staticcheck ./...                       # 16 findings, same as CI
```

`go env -w` persists in `~/.config/go/env`, so it survives new shells, and
`go env -w GOTOOLCHAIN=auto` undoes it. The pin is an exact patch version
while CI asks for `1.26` and floats, so they will diverge when CI picks up
1.26.8; that is deliberate, and re-pinning is a one-liner.

**One gap remains, on purpose.** `go.yml` builds, vets and tests on
`GO_VERSION: '1.21'`, matching the `go` directive in `go.mod`, so CI keeps
checking that the module still builds at its declared floor. The dev box now
runs 1.26.7 for everything. To reproduce a CI build exactly:

```bash
GOTOOLCHAIN=go1.21.13 go build ./...
```

Two things the rename shook out, both fixed:

* **gofmt.** Import blocks were sorted for `github.com/Telmate/...`; the new
  path sorts differently, so nine files became unformatted. `go.yml` does not
  check formatting, so CI would not have caught it. Consider adding a `fmt`
  job.
* **`make test_unit` does not exist at rc5.** That target arrived upstream
  later; rc5's Makefile has `test`. HEAD's `go.yml` called the newer name and
  the job failed instantly. Anything else inherited from HEAD's workflows
  should be checked against rc5's Makefile the same way.

**Known inherited debt: 16 `staticcheck` SA1019 findings.** Run 33369112350
measured 23; deleting the dead `resource_vm_qemu_test.go` cleared the 7 in it,
which were `TestCase.Providers`, superseded by `ProviderFactories`. What is
left is all shipping code:

| File | Findings | What |
| --- | --- | --- |
| `resource_pool.go` | 4 | non-Context CRUD fields |
| `resource_lxc_disk.go` | 4 | non-Context CRUD fields |
| `resource_storage_iso.go` | 3 | non-Context CRUD fields |
| `resource_lxc.go` | 3 | non-Context CRUD fields |
| `provider.go` | 1 | `Provider.ConfigureFunc` |
| `data_ha_group.go` | 1 | non-Context CRUD fields |

All pre-existing in rc5, none caused by the fork, and the `fork_*_test.go`
files add none. The `staticcheck` job is `continue-on-error: true`, so the run
still concludes success and a pull request stays mergeable ("unstable", not
blocked) while the signal remains visible. **Do not fix them in the drop-in
version**: moving to `CreateContext` changes cancellation behaviour, so it
belongs in a later release with its own testing, as part of the "align with Go
and Terraform practices" pass.

**The staticcheck job shows a red cross on every run, and that is deliberate
for now -- but revisit it.** The mechanics, so nobody re-diagnoses them:
`staticcheck ./...` exits non-zero whenever it reports anything, the non-zero
exit fails the step, and a failed step renders the job red.
`continue-on-error: true` only changes the *run's* conclusion, which stays
`success`, and whether the job blocks a merge, which it does not -- a pull
request sits at "unstable" and remains mergeable. The cross means "the 16
known deprecations are still there", not "something broke".

Kept as is on purpose: the debt stays visible rather than being quietly
suppressed. The cost is real though, and worth weighing later. **A check that
is permanently red trains people to ignore it**, and once ignored, a genuinely
new finding in that job is invisible -- nobody would notice the count going
from 16 to 17 without reading the log.

When this is revisited, the shape to consider, already verified: SA1019 is the
*only* failing check, and `staticcheck -checks 'inherit,-SA1019' ./...` exits
0 with zero findings on this tree. So the job can be split --

```yaml
- name: Run staticcheck
  run: staticcheck -checks 'inherit,-SA1019' ./...   # gates, must pass
- name: Known SA1019 debt (non-blocking)
  run: staticcheck -checks 'SA1019' ./... || true    # stays visible in the log
```

-- and `continue-on-error` dropped, which makes any *new* finding fail the job
and mean something again. What that costs is catching newly introduced uses of
deprecated APIs, which is why it is a trade rather than an obvious win, and why
the natural moment for it is the "align with Go and Terraform practices" pass
that re-enables SA1019 anyway by fixing the 16.

**Watch the staticcheck version, because an old one reports a false all-clear.**
v0.4.7 and v0.5.1 both report **zero** SA1019 on this tree -- not zero
findings overall, they still return 177 with `-checks all`, they just do not
flag these. Only v0.6 and later detect them. So a local run with whatever is
already in `~/go/bin` can look clean when it is not. The workflow pins
`@v0.8.1` and gives that job its own Go 1.26, because each staticcheck release
demands a newer toolchain to install: v0.5.1 needs 1.22.1, v0.6.x needs 1.23,
v0.8.1 needs 1.26. Installing `@latest` is what broke the job before -- it
floated to v0.8.1, failed at install against the 1.21 toolchain, skipped the
run step, and quietly stopped analysing anything at all.

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

**`resource_vm_qemu_test.go` has since been deleted.** It could not compile
against the rc5 schema -- its fixtures still set the top level `iso` argument
removed in `2808e32` -- so it was dead code that contributed 7 of the 23
SA1019 findings and nothing else. What it covered is recorded under
"Deferred", so the coverage ideas survive the file.

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

**Caches are also scoped to the branch that wrote them.** A cache created on a
topic branch is invisible to every other topic branch; only caches on the
default branch are visible to all. So a series of stage branches each rebuilds
and re-saves the same image, under the same key, without ever seeing the
others. Landing the acceptance suite in four stages cost four identical 8.4
images -- 11.35GB, over the limit again, on 2026-08-31 -- and three wasted
image builds. Once this is merged to `main` the nightly writes a
default-branch cache that every branch can restore, and the problem goes away;
until then, prune after a run of stage branches, or run them all on one branch.

This bit us on 2026-08-27 too: four images, 11.27GB, over the limit and
evicting.
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

**All nine pass against Proxmox VE 8.4** (run 33339420644) **and against
Proxmox VE 9.2** (run 33340162770), the latter once `VM.Monitor` was dropped
from the minimum permission list. On PVE 9 the rc5 rehearsal skips itself, for
the reason under "Migration ordering" below. They were landed one group at a time, each gated on
the previous being green, which is what made every failure readable. Keep that
habit when adding more.

What running them for the first time actually found -- five failures, none of
them flaky, every one a fact about the provider or the environment worth
keeping:

1. **`vmid` is never written to state.** rc5 has no `d.Set("vmid", ...)`
   anywhere; the attribute is Optional+Computed+ForceNew but only ever read
   *from* configuration (`resource_vm_qemu.go:794`). Tests assert on the
   resource id instead. This is also the real explanation for the three
   production VMs with no vmid -- their configs do not name one.
2. **Import does not populate `target_node`, `automatic_reboot`, `skip_ipv4`,
   `skip_ipv6` or `vcpus`**, `target_node` included, though the resource id
   carries the node. They are on the `ImportStateVerifyIgnore` list.
3. **`proxmox_pool` does not populate `poolid` on import** either
   (`_resourcePoolRead` sets only `comment`). Sharper than it looks: `poolid`
   is Required+ForceNew, so a pool adopted by import shows a *replacement* on
   the next plan. Anyone importing pools needs to know.
4. **A reboot-requiring update cannot be tested on a VM with no OS.**
   `rebootRequired` comes back from `config.Update()`
   (`resource_vm_qemu.go:1004`) and the API library performs the powerdown
   itself, ahead of the provider's force-stop fallback, so there is no
   recovery. A PXE VM never answers ACPI and the apply dies with "VM
   quit/powerdown failed - got timeout" after ~3.5 minutes. `_UpdateInPlace`
   therefore runs against a stopped VM, which also lets it cover memory.
5. **`TESTARGS` must not contain shell metacharacters** -- see below.

None of the provider behaviours above were fixed. Changing what lands in state
is exactly what a drop-in migration must not do; they are recorded so the
decision is deliberate rather than forgotten.

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
* **What the deleted upstream tests covered**, kept as a checklist rather than
  as code, since none of it could run: basic create, a "standard" create with
  more attributes set, clone from a source VM, clone with two disks, PXE
  create, an update needing no reboot, and an update requiring one. PXE create
  and both update shapes are covered now; clone is not, and does not appear in
  the state we run.
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

**The prerelease pin resolves.** `VersionConstraint: "3.0.1-rc5"` installs
from the registry without complaint, so no filesystem mirror is needed.
Overridable with `PVE_TEST_UPSTREAM_VERSION`. These remain the only tests
needing the network beyond the local Proxmox VM.

**Both steps must name the same provider address, and that takes an explicit
`terraform` block in the configuration.** `mergedConfig` (the SDK's
`teststep_providers.go`) generates `required_providers` only for steps
declaring `ExternalProviders`, and returns the configuration untouched the
moment it finds a `terraform {` block of its own. A `ProviderFactories` step
otherwise gets nothing, terraform infers the source from the resource type
prefix -- `registry.opentofu.org/hashicorp/proxmox` -- while the baseline step
locked `telmate/proxmox`, and step two dies with "Inconsistent dependency lock
file". `forkRequiredProviders()` writes the block; the version is pinned only
on the baseline step, since the lock file it writes keeps the rest consistent.

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

The workflow's default `testargs` tracks the stage table above.

**`TESTARGS` must not contain shell metacharacters.** The Makefile expands it
unquoted into `go test ./proxmox $(TESTARGS)`, so a `-run` regex using
alternation dies before the tests start:

```
/bin/bash: -c: line 1: syntax error near unexpected token `('
```

This is why the default is the bare prefix `-run=TestAccFork` rather than
`-run=TestAccFork(VmQemu|Pool)_`. Select a subset with a prefix -- the test
names are grouped for it: `TestAccForkVmQemu_`, `TestAccForkPool_`,
`TestAccForkUpgrade_`.

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

### Migration ordering is now settled, and it is one way only

Running the suite against Proxmox VE 9.2 turned the PVE 9 blocker from a code
reading into a measurement, and then into a constraint on the real migration.

Before the backport (run 33339630438) **all nine tests failed in under three
seconds each**, at provider configuration, before touching a VM:

```
permissions for user/token root@pam are not sufficient, please provide also the
following permissions that are missing: [VM.Monitor]
```

The environment was healthy throughout -- the image built, the node came up,
the hypervisor level boot test passed -- so the provider was the only thing in
the way. After dropping the privilege (run 33340162770) everything passes
except `TestAccForkUpgrade_FromUpstreamRc5`, which still reports `VM.Monitor`,
and correctly: **step one of that test runs the genuine upstream v3.0.1-rc5
pulled from the registry**, which our one line fix cannot reach.

So, stated plainly:

* The **fork** works on Proxmox VE 9, with that single backport.
* **Upstream v3.0.1-rc5 does not**, on any account including `root@pam`,
  because the privilege it demands no longer exists to be granted.

**Therefore the migration has an order, and only one works: move production
onto the fork while it is still on Proxmox 8, then upgrade Proxmox to 9.** The
reverse has no starting point -- after a PVE 9 upgrade the provider production
runs today cannot configure, so there is nothing to migrate *from*, and the
cluster would be stranded until the provider swap happened anyway, unplanned
and under pressure.

The rehearsal test skips itself on PVE 9 rather than pretending otherwise.

### Next

Done since this was last written: the suite runs green on both versions, the
`3.0.1-rc5` prerelease resolves from the registry, and `VM.Monitor` is
backported.

1. Merge `acceptance-tests` into `main` so the nightly schedule picks it up.
   Prune the epoch 2 images afterwards -- four images at ~2.5GB each against a
   10GB limit.
2. Consider backporting `pm_minimum_permission_check` /
   `pm_minimum_permission_list`, so the next privilege rename is configuration
   rather than a code change and a release.
3. Look at the `count` based resource (`proxmox_vm_qemu.testvms`, 2 instances)
   before rehearsing the state rewrite. The three VMs with no `vmid` are
   understood now and need no action.
4. Rehearse the state migration on a copy of a production state file and
   confirm `tofu plan` is empty. Do this **while still on Proxmox 8** -- see
   "Migration ordering" above.
5. Cut `0.9.0`, then set `PVE_TEST_PREVIOUS_VERSION` so
   `TestAccForkUpgrade_FromPreviousRelease` stops skipping. Until a release
   exists it cannot run, and it is the test that matters most long term.
6. Add tests as the need appears, not in advance. HA is the biggest known gap;
   a reboot-requiring update of a running VM is the second.
7. Revisit the permanently red `staticcheck` job -- see "shows a red cross"
   above. Not urgent, but it should not stay red indefinitely, because a check
   nobody trusts is worth less than no check.

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
* The acceptance tests default to the node name `testproxmox` and expect
  `local` storage to accept disk images, a `local:iso/SpinRite.iso`, and the
  `vmbr0` and `vmbr1` bridges. In the fork's own tests every one of those is
  an override (`PVE_TEST_NODE_NAME`, `PVE_TEST_STORAGE`, `PVE_TEST_BRIDGE`,
  `PVE_TEST_BRIDGE2`, `PVE_TEST_ISO`) rather than a hardcoded constant, so the
  suite can be pointed at a real cluster.
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

## Upstream automation: two adopted, two still parked

`.github/workflows/` holds `acceptance-test.yml`, `go.yml` and `release.yml`.
`.github/disabled-upstream/` still holds `manage_issues.yml` and
`dependabot.yml`, which GitHub does not scan there. See the README in that
directory for what each one did.

**Adopted**, both rewritten for the fork rather than taken as they were:

* `go.yml` -- verify-dependencies, build, vet, staticcheck and unit tests, on
  push and pull request against `main`, plus `workflow_dispatch` so a branch
  that is not yet the default can still be built. `staticcheck` is
  `continue-on-error` because of the 23 inherited SA1019 findings.
* `release.yml` -- GoReleaser on `v*` tags, `contents: write`, needing the
  `GPG_PRIVATE_KEY` and `PASSPHRASE` secrets. It fires on the fork's own tags;
  the concern about upstream's 51 tags only applies if those are ever pushed
  here, and they should not be.

**Still parked, and staying that way:** `dependabot.yml` would start moving
dependencies, which is precisely what the fork exists to control, and
`manage_issues.yml` is housekeeping for a busy public tracker.

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
