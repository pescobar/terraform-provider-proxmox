package proxmox

import (
	"fmt"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/resource"
)

const forkHaRuleResource = "proxmox_ha_rule.test"

// forkHaRuleHCL builds a node-affinity rule over the VM declared alongside it.
// The sid has to be "vm:<vmid>", and the provider does not expose vmid as an
// attribute -- rc5 never writes it -- so it is taken from the resource id,
// which is "<node>/qemu/<vmid>".
func forkHaRuleHCL(vm forkVM, ruleName, comment string, strict bool) string {
	return vm.hcl() + fmt.Sprintf(`
resource "proxmox_ha_rule" "test" {
  rule      = %q
  type      = "node-affinity"
  comment   = %q
  strict    = %t
  resources = ["vm:${element(split("/", proxmox_vm_qemu.test.id), 2)}"]

  nodes = {
    %q = 5
  }
}
`, ruleName, comment, strict, forkNode())
}

// TestAccForkHaRule covers proxmox_ha_rule, which exists to adopt what a
// Proxmox 8 -> 9 upgrade produces: every HA group is converted to a
// node-affinity rule, under a generated identifier, with the old group name
// left in the comment.
//
// Proxmox 9 only. The endpoint does not exist before it -- the client library
// upstream now pins gates it with "HA rules require Proxmox VE 9.0 or higher"
// -- so on 8.4 this skips rather than failing.
func TestAccForkHaRule(t *testing.T) {
	if forkEnv("PVE_TEST_PVE_VERSION", "") == "8" {
		t.Skip("proxmox_ha_rule requires Proxmox VE 9; HA groups are the mechanism on 8")
	}

	vm := forkBaseVM(forkVMName())
	vm.HAState = "ignored" // registers the guest with HA without the CRM racing us for its power state
	name := "tf-acc-" + forkVMName()[7:]

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		CheckDestroy:      forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{
				Config: forkHaRuleHCL(vm, name, "converted-from-group", false),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists(forkVMResource),
					resource.TestCheckResourceAttr(forkHaRuleResource, "rule", name),
					resource.TestCheckResourceAttr(forkHaRuleResource, "type", "node-affinity"),
					resource.TestCheckResourceAttr(forkHaRuleResource, "comment", "converted-from-group"),
					resource.TestCheckResourceAttr(forkHaRuleResource, "resources.#", "1"),
					resource.TestCheckResourceAttr(forkHaRuleResource, "nodes."+forkNode(), "5"),
					// Assigned by Proxmox, and the lock token for updates.
					resource.TestCheckResourceAttrSet(forkHaRuleResource, "digest"),
					resource.TestCheckResourceAttrSet(forkHaRuleResource, "order"),
				),
			},
			{
				// No drift: the API returns resources and nodes as strings in
				// its own order, and this proves the set and map handling
				// normalises both.
				Config:   forkHaRuleHCL(vm, name, "converted-from-group", false),
				PlanOnly: true,
			},
			{
				// The path that matters after an upgrade: adopt a rule that
				// already exists, by its generated identifier.
				Config:            forkHaRuleHCL(vm, name, "converted-from-group", false),
				ResourceName:      forkHaRuleResource,
				ImportState:       true,
				ImportStateVerify: true,
			},
			{
				// Update in place: comment and strict are the two a converted
				// rule is most likely to need changing.
				Config: forkHaRuleHCL(vm, name, "managed-by-tofu", true),
				Check: resource.ComposeTestCheckFunc(
					resource.TestCheckResourceAttr(forkHaRuleResource, "comment", "managed-by-tofu"),
					resource.TestCheckResourceAttr(forkHaRuleResource, "strict", "true"),
				),
			},
			{
				// A second update straight after the first, without an
				// intervening refresh.  This is the shape that fails when the
				// digest is sent: the previous write changed the file-wide
				// checksum, so the value still in state is stale and Proxmox
				// answers "detected modified configuration - file changed by
				// other user? Try again."
				Config: forkHaRuleHCL(vm, name, "managed-by-tofu-again", false),
				Check: resource.ComposeTestCheckFunc(
					resource.TestCheckResourceAttr(forkHaRuleResource, "comment", "managed-by-tofu-again"),
					resource.TestCheckResourceAttr(forkHaRuleResource, "strict", "false"),
				),
			},
		},
	})
}

// forkHaRuleMultiHCL renders one or two guests and a node-affinity rule over
// them.  The sids are interpolated from the guests' ids, so the rule depends on
// them and Terraform orders creation correctly.
func forkHaRuleMultiHCL(vms []forkVM, ruleName string) string {
	cfg := ""
	sids := make([]string, 0, len(vms))
	for _, vm := range vms {
		cfg += vm.hcl()
		sids = append(sids, fmt.Sprintf(
			`"vm:${element(split("/", proxmox_vm_qemu.%s.id), 2)}"`, vm.ResourceName))
	}
	return cfg + fmt.Sprintf(`
resource "proxmox_ha_rule" "test" {
  rule      = %q
  type      = "node-affinity"
  comment   = "guest removal"
  resources = [%s]

  nodes = {
    %q = 1
  }
}
`, ruleName, strings.Join(sids, ", "), forkNode())
}

// TestAccForkHaRule_GuestRemoved covers removing a guest and taking it out of a
// rule in the same apply, which is what a real cluster reported failing with
//
//	500 update HA rules failed: detected modified configuration -
//	file changed by other user? Try again.
//
// Proxmox strips a destroyed guest's sid from every rule referencing it, so the
// rules file changes underneath the apply.  While the provider sent the digest
// it had read at refresh, the write was then rejected.
//
// What this test does *not* do is guarantee it reproduces that.  Once the guest
// is gone from the configuration, nothing references it, so Terraform is free
// to update the rule before destroying the guest -- and in that order the
// digest would still have matched.  It reproduces when the destroy happens
// first, which is the order the reported failure took.
//
// It earns its place regardless: removing a guest that a rule references is an
// ordinary operation, it was not covered, and both orderings must end with the
// rule holding only the surviving guest.
func TestAccForkHaRule_GuestRemoved(t *testing.T) {
	if forkEnv("PVE_TEST_PVE_VERSION", "") == "8" {
		t.Skip("proxmox_ha_rule requires Proxmox VE 9")
	}

	keep := forkBaseVM(forkVMName())
	keep.ResourceName = "keep"
	keep.HAState = "ignored" // HA managed, without the CRM racing for its power state

	drop := forkBaseVM(forkVMName())
	drop.ResourceName = "drop"
	drop.HAState = "ignored"

	name := "tf-acc-" + forkVMName()[7:]

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		CheckDestroy:      forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{
				Config: forkHaRuleMultiHCL([]forkVM{keep, drop}, name),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists("proxmox_vm_qemu.keep"),
					forkCheckVMExists("proxmox_vm_qemu.drop"),
					resource.TestCheckResourceAttr(forkHaRuleResource, "resources.#", "2"),
				),
			},
			{
				// One guest gone from the configuration and from the rule, in
				// a single apply.
				Config: forkHaRuleMultiHCL([]forkVM{keep}, name),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists("proxmox_vm_qemu.keep"),
					resource.TestCheckResourceAttr(forkHaRuleResource, "resources.#", "1"),
				),
			},
			{
				// And the result is stable: no leftover sid, no perpetual diff.
				Config:   forkHaRuleMultiHCL([]forkVM{keep}, name),
				PlanOnly: true,
			},
		},
	})
}
