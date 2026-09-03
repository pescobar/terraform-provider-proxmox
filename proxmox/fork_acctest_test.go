package proxmox

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"

	pxapi "github.com/Telmate/proxmox-api-go/proxmox"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/acctest"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/resource"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
	"github.com/hashicorp/terraform-plugin-sdk/v2/terraform"
)

// Shared scaffolding for the fork's acceptance tests.
//
// These are new tests written against the rc5 schema.  The inherited
// upstream tests in resource_vm_qemu_test.go cannot pass -- they still
// configure a top level `iso` argument that was removed in 2808e32, an
// ancestor of v3.0.1-rc5 -- so nothing here builds on them.  Everything
// the fork adds is prefixed `fork` / `TestAccFork` so the delta against
// upstream stays legible.

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// The defaults match what test/acceptance/guest/ provisions inside the
// throwaway Proxmox VM.  They are overridable so the same suite can be
// pointed at a real cluster, where the names will be different.
//
// The names are deliberately generic: the tests assert on the provider's
// behaviour, not on any particular site's naming.

func forkEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func forkNode() string    { return forkEnv("PVE_TEST_NODE_NAME", "testproxmox") }
func forkStorage() string { return forkEnv("PVE_TEST_STORAGE", "local") }
func forkBridge() string  { return forkEnv("PVE_TEST_BRIDGE", "vmbr0") }
func forkBridge2() string { return forkEnv("PVE_TEST_BRIDGE2", "vmbr1") }
func forkISO() string     { return forkEnv("PVE_TEST_ISO", "local:iso/SpinRite.iso") }
func forkHAGroup() string { return forkEnv("PVE_TEST_HA_GROUP", "acctest-ha") }

// forkVMName returns a unique, DNS safe name.  Proxmox rejects anything else.
func forkVMName() string {
	return "tf-acc-" + strings.ToLower(acctest.RandStringFromCharSet(8, acctest.CharSetAlpha))
}

// ---------------------------------------------------------------------------
// Provider plumbing
// ---------------------------------------------------------------------------

// forkTestProvider keeps a handle on the configured provider so check
// functions can reach the API client through its meta.
var forkTestProvider *schema.Provider

func forkProviderFactories() map[string]func() (*schema.Provider, error) {
	if forkTestProvider == nil {
		forkTestProvider = Provider()
	}
	return map[string]func() (*schema.Provider, error){
		"proxmox": func() (*schema.Provider, error) { return forkTestProvider, nil },
	}
}

func forkPreCheck(t *testing.T) {
	t.Helper()
	for _, v := range []string{"PM_API_URL", "PM_USER", "PM_PASS"} {
		if os.Getenv(v) == "" {
			t.Fatalf("%s must be set for acceptance tests "+
				"(source test/acceptance/scripts/env.sh)", v)
		}
	}
}

func forkAPIClient() (*pxapi.Client, error) {
	if forkTestProvider == nil || forkTestProvider.Meta() == nil {
		return nil, fmt.Errorf("provider is not configured yet")
	}
	pconf, ok := forkTestProvider.Meta().(*providerConfiguration)
	if !ok {
		return nil, fmt.Errorf("unexpected provider meta type %T", forkTestProvider.Meta())
	}
	return pconf.Client, nil
}

// ---------------------------------------------------------------------------
// Check functions
// ---------------------------------------------------------------------------

func forkVMIDFromState(s *terraform.State, name string) (int, error) {
	rs, ok := s.RootModule().Resources[name]
	if !ok {
		return 0, fmt.Errorf("resource not found in state: %s", name)
	}
	if rs.Primary.ID == "" {
		return 0, fmt.Errorf("resource %s has no id", name)
	}
	_, _, vmID, err := parseResourceId(rs.Primary.ID)
	if err != nil {
		return 0, fmt.Errorf("unparsable id %q on %s: %w", rs.Primary.ID, name, err)
	}
	return vmID, nil
}

// forkCheckVMExists asserts the VM is really on the cluster, not merely in
// state.  Every create test uses it: state saying a VM exists is exactly the
// thing under test.
func forkCheckVMExists(name string) resource.TestCheckFunc {
	return func(s *terraform.State) error {
		vmID, err := forkVMIDFromState(s, name)
		if err != nil {
			return err
		}
		client, err := forkAPIClient()
		if err != nil {
			return err
		}
		if _, err := client.GetVmInfo(pxapi.NewVmRef(vmID)); err != nil {
			return fmt.Errorf("vm %d is in state but not on the cluster: %w", vmID, err)
		}
		return nil
	}
}

// forkCheckVMsDestroyed is the CheckDestroy for every VM test.
func forkCheckVMsDestroyed(s *terraform.State) error {
	client, err := forkAPIClient()
	if err != nil {
		// Nothing was ever configured, so nothing can have leaked.
		return nil
	}
	for name, rs := range s.RootModule().Resources {
		if rs.Type != "proxmox_vm_qemu" || rs.Primary.ID == "" {
			continue
		}
		_, _, vmID, err := parseResourceId(rs.Primary.ID)
		if err != nil {
			continue
		}
		if _, err := client.GetVmInfo(pxapi.NewVmRef(vmID)); err == nil {
			return fmt.Errorf("vm %d (%s) still exists after destroy", vmID, name)
		}
	}
	return nil
}

// forkRecordVMID stores the VM's id so a later step can prove the VM was
// updated in place rather than destroyed and recreated.  A recreate is the
// failure mode that matters most here: it would mean a production migration
// rebuilds 70 machines.
func forkRecordVMID(name string, out *int) resource.TestCheckFunc {
	return func(s *terraform.State) error {
		vmID, err := forkVMIDFromState(s, name)
		if err != nil {
			return err
		}
		*out = vmID
		return nil
	}
}

func forkCheckVMIDUnchanged(name string, want *int) resource.TestCheckFunc {
	return func(s *terraform.State) error {
		vmID, err := forkVMIDFromState(s, name)
		if err != nil {
			return err
		}
		if *want == 0 {
			return fmt.Errorf("no vmid was recorded by an earlier step")
		}
		if vmID != *want {
			return fmt.Errorf("vm was recreated: vmid changed from %d to %d", *want, vmID)
		}
		return nil
	}
}

// ---------------------------------------------------------------------------
// Configuration builder
// ---------------------------------------------------------------------------

// forkVM describes the VM shape the tests exercise.  The zero value is not
// useful; start from forkBaseVM().
type forkVM struct {
	Name     string
	Cores    int
	Memory   int
	Balloon  int
	Tags     string
	VMState  string
	DiskSize string
	Format   string

	Protection bool
	SecondDisk bool // a second data disk on virtio1
	CDROM      bool // a cdrom on ide2
	SecondNIC  bool // a second interface on the secondary bridge

	// HA needs a quorate cluster, which the test image builds on first boot.
	// Empty means the attribute is left out of the configuration entirely.
	HAState string
	HAGroup string
}

// forkBaseVM is the shape the fork has to keep working: a PXE booted VM with
// no cloud-init and no clone, which is what the provider is actually used for.
// The OS is installed out of band, so the provider's job ends once the VM
// exists and is running.
func forkBaseVM(name string) forkVM {
	return forkVM{
		Name:     name,
		Cores:    2,
		Memory:   2048,
		Balloon:  2048,
		Tags:     "acctest;base",
		VMState:  "running",
		DiskSize: "8G",
		Format:   "qcow2",
	}
}

func (v forkVM) hcl() string {
	var b strings.Builder

	fmt.Fprintf(&b, `
resource "proxmox_vm_qemu" "test" {
  name        = %q
  target_node = %q

  # PXE booted: the OS is installed out of band, so there is no clone and no
  # cloud-init.  pxe conflicts with clone, which keeps the two paths apart.
  pxe  = true
  boot = "order=virtio0;net0"

  # define_connection_info MUST stay false.  It defaults to true, and with
  # agent = 1 the provider then blocks in initConnInfo waiting for a guest
  # agent that a VM with no OS never starts -- for the full 20 minute create
  # timeout.  Turning it off is also what the schema is used for in practice.
  define_connection_info = false
  agent                  = 1

  bios     = "seabios"
  scsihw   = "virtio-scsi-single"
  qemu_os  = "l26"
  onboot   = false
  hotplug  = "cpu,network,disk,usb"

  cpu_type = "host"
  sockets  = 1
  cores    = %d
  memory   = %d
  balloon  = %d

  vm_state   = %q
  tags       = %q
  protection = %t
`, v.Name, forkNode(), v.Cores, v.Memory, v.Balloon, v.VMState, v.Tags, v.Protection)

	b.WriteString("\n  disks {\n    virtio {\n      virtio0 {\n        disk {\n")
	fmt.Fprintf(&b, "          storage  = %q\n", forkStorage())
	fmt.Fprintf(&b, "          size     = %q\n", v.DiskSize)
	fmt.Fprintf(&b, "          format   = %q\n", v.Format)
	b.WriteString("          backup   = true\n")
	b.WriteString("          iothread = true\n")
	b.WriteString("        }\n      }\n")

	if v.SecondDisk {
		b.WriteString("      virtio1 {\n        disk {\n")
		fmt.Fprintf(&b, "          storage  = %q\n", forkStorage())
		b.WriteString("          size     = \"1G\"\n")
		fmt.Fprintf(&b, "          format   = %q\n", v.Format)
		b.WriteString("          backup   = true\n")
		b.WriteString("          iothread = true\n")
		b.WriteString("        }\n      }\n")
	}
	b.WriteString("    }\n")

	if v.CDROM {
		b.WriteString("    ide {\n      ide2 {\n        cdrom {\n")
		fmt.Fprintf(&b, "          iso = %q\n", forkISO())
		b.WriteString("        }\n      }\n    }\n")
	}
	b.WriteString("  }\n")

	if v.HAState != "" {
		fmt.Fprintf(&b, "\n  hastate = %q\n", v.HAState)
	}
	if v.HAGroup != "" {
		fmt.Fprintf(&b, "  hagroup = %q\n", v.HAGroup)
	}

	fmt.Fprintf(&b, "\n  network {\n    id     = 0\n    model  = \"virtio\"\n    bridge = %q\n  }\n", forkBridge())
	if v.SecondNIC {
		fmt.Fprintf(&b, "\n  network {\n    id     = 1\n    model  = \"virtio\"\n    bridge = %q\n  }\n", forkBridge2())
	}

	b.WriteString("}\n")
	return b.String()
}

// forkCheckHAResource asserts the guest is registered with the HA manager, and
// that its group matches.  State saying so is not enough: the provider writes
// hastate and hagroup from configuration during create, so only the cluster
// can confirm the call actually landed.
func forkCheckHAResource(name, wantGroup string) resource.TestCheckFunc {
	return func(s *terraform.State) error {
		vmID, err := forkVMIDFromState(s, name)
		if err != nil {
			return err
		}
		client, err := forkAPIClient()
		if err != nil {
			return err
		}
		raw, err := client.GetItemConfigMapStringInterface(
			"/cluster/ha/resources/vm:"+strconv.Itoa(vmID), "ha", "config")
		if err != nil {
			return fmt.Errorf("vm %d is not an HA resource: %w", vmID, err)
		}
		if wantGroup != "" {
			got, _ := raw["group"].(string)
			if got != wantGroup {
				return fmt.Errorf("vm %d is in HA group %q, want %q", vmID, got, wantGroup)
			}
		}
		return nil
	}
}
