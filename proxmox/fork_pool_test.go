package proxmox

import (
	"fmt"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/acctest"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/resource"
)

const forkPoolResource = "proxmox_pool.test"

func forkPoolName() string {
	return "tfacc" + strings.ToLower(acctest.RandStringFromCharSet(8, acctest.CharSetAlpha))
}

func forkPoolHCL(poolID, comment string) string {
	return fmt.Sprintf(`
resource "proxmox_pool" "test" {
  poolid  = %q
  comment = %q
}
`, poolID, comment)
}

// TestAccForkPool_Basic covers proxmox_pool end to end.  It is cheap, and it
// is the one test that exercises the pool API surface -- which on Proxmox 9
// needs the Pool.Audit privilege that rc5's hardcoded minimum permission list
// does not know about.  If the permission backport regresses, this fails
// before any VM test does.
func TestAccForkPool_Basic(t *testing.T) {
	poolID := forkPoolName()

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		Steps: []resource.TestStep{
			{
				Config: forkPoolHCL(poolID, "created by the acceptance tests"),
				Check: resource.ComposeTestCheckFunc(
					resource.TestCheckResourceAttr(forkPoolResource, "poolid", poolID),
					resource.TestCheckResourceAttr(forkPoolResource, "comment", "created by the acceptance tests"),
				),
			},
			{
				// comment is the only mutable attribute; poolid is ForceNew.
				Config: forkPoolHCL(poolID, "updated by the acceptance tests"),
				Check: resource.TestCheckResourceAttr(
					forkPoolResource, "comment", "updated by the acceptance tests"),
			},
			{
				Config:            forkPoolHCL(poolID, "updated by the acceptance tests"),
				ResourceName:      forkPoolResource,
				ImportState:       true,
				ImportStateVerify: true,
				// poolid is not populated on import: _resourcePoolRead sets
				// only `comment`, and the id it parses is "pools/<name>".
				//
				// That is a sharper edge than it looks.  poolid is
				// Required+ForceNew, so a pool adopted by import and then
				// planned shows a change from "" to its name on a ForceNew
				// attribute -- that is, a replacement.  Anyone importing pools
				// rather than creating them needs to know.  Recorded here
				// rather than fixed: changing what read writes to state is a
				// state change, and the drop-in release must not make one.
				ImportStateVerifyIgnore: []string{
					"poolid",
					"timeouts",
				},
			},
		},
	})
}
