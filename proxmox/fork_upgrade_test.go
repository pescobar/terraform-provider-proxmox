package proxmox

import (
	"fmt"
	"os"
	"testing"

	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/resource"
)

// Provider upgrade tests.
//
// These are the reason the fork exists.  Upstream shipped breaking schema
// changes with no SchemaVersion and no StateUpgraders, so an upgrade could
// only be validated by running it.  These tests run it.
//
// How they work: helper/resource builds TF_REATTACH_PROVIDERS keyed as
// host/namespace/name, taking host and namespace from TF_ACC_PROVIDER_HOST
// and TF_ACC_PROVIDER_NAMESPACE (see the SDK's plugin.go, getProviderAddr).
// Setting those to the address a state file already records makes the
// in-process provider answer for that address.  So one step can create
// resources with a released provider downloaded from the registry, and the
// next step can read that state with the code in this working tree.
//
// Providers are declared per step rather than on the TestCase: the SDK
// rejects a case that specifies providers at both levels.

// forkUpgradeSource returns the registry source and version that step one
// should install.
func forkUpgradeSource(t *testing.T, hostEnv, nsEnv, sourceEnv, versionEnv, defaultSource, defaultVersion string) (string, string) {
	t.Helper()

	version := forkEnv(versionEnv, defaultVersion)
	if version == "" {
		t.Skipf("%s is not set: no baseline version to upgrade from", versionEnv)
	}

	// Make the in-process provider answer for the same address the baseline
	// wrote into state, so the later steps can read it.
	t.Setenv("TF_ACC_PROVIDER_HOST", forkEnv(hostEnv, "registry.opentofu.org"))
	t.Setenv("TF_ACC_PROVIDER_NAMESPACE", forkEnv(nsEnv, defaultNamespace(defaultSource)))

	return forkEnv(sourceEnv, defaultSource), version
}

// forkRequiredProviders renders a terraform block naming the provider address
// explicitly.
//
// This is load bearing.  mergedConfig (the SDK's teststep_providers.go) returns
// the configuration untouched as soon as it finds a "terraform {" block in it,
// and otherwise generates one only for steps that declare ExternalProviders.
// A ProviderFactories step therefore gets no required_providers at all, and
// terraform infers the source from the resource type prefix -- registry
// default namespace, so registry.opentofu.org/hashicorp/proxmox.  The baseline
// step meanwhile locks registry.opentofu.org/telmate/proxmox, and the run dies
// on step two with "Inconsistent dependency lock file ... hashicorp/proxmox:
// required by this configuration but no version is selected".
//
// Writing the block ourselves puts every step on one address, which is the
// whole point: the fork has to read state the baseline wrote.
//
// The version is pinned only for the baseline step.  Without it the baseline
// would install the newest published provider rather than the one production
// runs; with it on the later steps, we would be claiming the working tree is
// that version.  The lock file written by step one keeps the later steps
// consistent on its own.
func forkRequiredProviders(source, version string) string {
	var pin string
	if version != "" {
		pin = fmt.Sprintf("      version = %q\n", version)
	}
	return fmt.Sprintf(`terraform {
  required_providers {
    proxmox = {
      source = %q
%s    }
  }
}
`, source, pin)
}

func defaultNamespace(source string) string {
	for i := 0; i < len(source); i++ {
		if source[i] == '/' {
			return source[:i]
		}
	}
	return source
}

// TestAccForkUpgrade_FromUpstreamRc5 is the migration rehearsal: the
// upstream provider production runs today creates a VM, then the fork takes
// over the same state and must find nothing to do.
//
// An empty plan in step two is the acceptance criterion for moving production
// onto the fork.  Step three additionally requires the VM to survive: a
// changed vmid would mean the migration rebuilds every machine.
//
// This is the only test that needs the network beyond the Proxmox VM: step one
// downloads the baseline provider from the registry.
func TestAccForkUpgrade_FromUpstreamRc5(t *testing.T) {
	source, version := forkUpgradeSource(t,
		"PVE_TEST_UPSTREAM_HOST", "PVE_TEST_UPSTREAM_NAMESPACE",
		"PVE_TEST_UPSTREAM_SOURCE", "PVE_TEST_UPSTREAM_VERSION",
		"telmate/proxmox", "3.0.1-rc5")

	cfg := forkBaseVM(forkVMName())
	cfg.CDROM = true
	cfg.SecondDisk = true

	baselineConfig := forkRequiredProviders(source, version) + cfg.hcl()
	forkConfig := forkRequiredProviders(source, "") + cfg.hcl()

	var vmID int

	resource.Test(t, resource.TestCase{
		PreCheck:     func() { forkPreCheck(t) },
		CheckDestroy: forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{
				// The baseline provider, from the registry, writes the state.
				ExternalProviders: map[string]resource.ExternalProvider{
					"proxmox": {Source: source, VersionConstraint: version},
				},
				Config: baselineConfig,
			},
			{
				// The fork reads that state.  Nothing may have changed.
				ProviderFactories: forkProviderFactories(),
				Config:            forkConfig,
				PlanOnly:          true,
			},
			{
				// And it must adopt the VM rather than replace it.
				ProviderFactories: forkProviderFactories(),
				Config:            forkConfig,
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists(forkVMResource),
					forkRecordVMID(forkVMResource, &vmID),
					resource.TestCheckResourceAttr(forkVMResource, "name", cfg.Name),
					resource.TestCheckResourceAttrSet(forkVMResource, "smbios.0.uuid"),
				),
			},
		},
	})
}

// TestAccForkUpgrade_FromPreviousRelease is the permanent version of the
// test above: every release has to be able to read the state its predecessor
// wrote.  Set PVE_TEST_PREVIOUS_VERSION to the last published version of this
// fork; without it there is no baseline and the test skips.
//
// This is the guarantee upstream never offered, so it is the one the fork
// should never break.  Any change that needs a SchemaVersion and
// StateUpgraders will fail here first.
func TestAccForkUpgrade_FromPreviousRelease(t *testing.T) {
	if os.Getenv("PVE_TEST_PREVIOUS_VERSION") == "" {
		t.Skip("PVE_TEST_PREVIOUS_VERSION is not set: no published release to upgrade from")
	}

	source, version := forkUpgradeSource(t,
		"PVE_TEST_PREVIOUS_HOST", "PVE_TEST_PREVIOUS_NAMESPACE",
		"PVE_TEST_PREVIOUS_SOURCE", "PVE_TEST_PREVIOUS_VERSION",
		"pescobar/proxmox", "")

	cfg := forkBaseVM(forkVMName())
	cfg.CDROM = true
	cfg.SecondDisk = true
	cfg.SecondNIC = true

	baselineConfig := forkRequiredProviders(source, version) + cfg.hcl()
	forkConfig := forkRequiredProviders(source, "") + cfg.hcl()

	var vmID int

	resource.Test(t, resource.TestCase{
		PreCheck:     func() { forkPreCheck(t) },
		CheckDestroy: forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{
				ExternalProviders: map[string]resource.ExternalProvider{
					"proxmox": {Source: source, VersionConstraint: version},
				},
				Config: baselineConfig,
			},
			{
				ProviderFactories: forkProviderFactories(),
				Config:            forkConfig,
				PlanOnly:          true,
			},
			{
				ProviderFactories: forkProviderFactories(),
				Config:            forkConfig,
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists(forkVMResource),
					forkRecordVMID(forkVMResource, &vmID),
				),
			},
		},
	})
}
