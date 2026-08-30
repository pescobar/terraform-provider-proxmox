package proxmox

import (
	"testing"

	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/resource"
)

const forkVMResource = "proxmox_vm_qemu.test"

// TestAccForkVmQemu_Minimal is the foundation: the smallest VM matching the
// shape the provider is actually used for.  If this fails nothing else in the
// suite means anything, so it asserts as little as possible beyond "the VM is
// really there".
func TestAccForkVmQemu_Minimal(t *testing.T) {
	cfg := forkBaseVM(forkVMName())

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		CheckDestroy:      forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{
				Config: cfg.hcl(),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists(forkVMResource),
					resource.TestCheckResourceAttr(forkVMResource, "name", cfg.Name),
					resource.TestCheckResourceAttr(forkVMResource, "target_node", forkNode()),
					resource.TestCheckResourceAttr(forkVMResource, "pxe", "true"),
					resource.TestCheckResourceAttrSet(forkVMResource, "vmid"),
				),
			},
		},
	})
}
