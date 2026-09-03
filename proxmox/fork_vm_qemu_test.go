package proxmox

import (
	"regexp"
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
					// Not `vmid`: rc5 never writes it back to state.  It is
					// Optional+Computed+ForceNew but only ever read from the
					// config, so a configuration that does not set it leaves
					// it absent from state for good -- which is exactly why
					// three VMs in the state we run have no vmid either.  The
					// id carries the real one, and forkCheckVMExists has
					// already resolved it against the API.
					resource.TestMatchResourceAttr(forkVMResource, "id",
						regexp.MustCompile(`^`+regexp.QuoteMeta(forkNode())+`/qemu/[0-9]+$`)),
				),
			},
		},
	})
}

// TestAccForkVmQemu_FullShape covers the whole set of attributes in routine
// use, and then re-plans the identical configuration.  The second step is the
// point of the test: an empty plan proves none of the Computed attributes --
// smbios.uuid, boot, vmid, macaddr -- drift on a refresh.  Drift there is what
// turns a provider swap into a fleet rebuild.
func TestAccForkVmQemu_FullShape(t *testing.T) {
	cfg := forkBaseVM(forkVMName())
	cfg.Cores = 2
	cfg.Memory = 2048
	cfg.Balloon = 1024
	cfg.Tags = "acctest;full;shape"
	cfg.SecondDisk = true
	cfg.CDROM = true
	cfg.SecondNIC = true

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		CheckDestroy:      forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{
				Config: cfg.hcl(),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists(forkVMResource),
					resource.TestCheckResourceAttr(forkVMResource, "scsihw", "virtio-scsi-single"),
					resource.TestCheckResourceAttr(forkVMResource, "cpu_type", "host"),
					resource.TestCheckResourceAttr(forkVMResource, "hotplug", "cpu,network,disk,usb"),
					resource.TestCheckResourceAttr(forkVMResource, "agent", "1"),
					resource.TestCheckResourceAttr(forkVMResource, "define_connection_info", "false"),
					resource.TestCheckResourceAttr(forkVMResource, "balloon", "1024"),
					// two data disks, a cdrom and two interfaces
					resource.TestCheckResourceAttr(forkVMResource,
						"disks.0.virtio.0.virtio0.0.disk.0.storage", forkStorage()),
					resource.TestCheckResourceAttr(forkVMResource,
						"disks.0.virtio.0.virtio1.0.disk.0.size", "1G"),
					resource.TestCheckResourceAttr(forkVMResource,
						"disks.0.ide.0.ide2.0.cdrom.0.iso", forkISO()),
					resource.TestCheckResourceAttr(forkVMResource, "network.#", "2"),
					resource.TestCheckResourceAttr(forkVMResource, "network.1.bridge", forkBridge2()),
					// smbios.uuid is Optional+Computed: it must come back populated
					resource.TestCheckResourceAttrSet(forkVMResource, "smbios.0.uuid"),
					// so is macaddr, on every interface
					resource.TestCheckResourceAttrSet(forkVMResource, "network.0.macaddr"),
					resource.TestCheckResourceAttrSet(forkVMResource, "network.1.macaddr"),
				),
			},
			{
				// The regression net: same config, no changes expected.
				Config:   cfg.hcl(),
				PlanOnly: true,
			},
		},
	})
}

// TestAccForkVmQemu_Import proves an existing VM can be adopted from the
// cluster and that every attribute round-trips.  This is the closest thing in
// the suite to the production migration: state written by one thing, read back
// by another, with the two required to agree.
func TestAccForkVmQemu_Import(t *testing.T) {
	cfg := forkBaseVM(forkVMName())
	cfg.CDROM = true

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		CheckDestroy:      forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{Config: cfg.hcl()},
			{
				Config:            cfg.hcl(),
				ResourceName:      forkVMResource,
				ImportState:       true,
				ImportStateVerify: true,
				// Not attributes of the VM: these exist only to drive the
				// provider, so an imported resource has no value for them.
				// Two groups here.  The first drive the provider rather than
				// describe the VM, so an imported resource has no value for
				// them.  The second -- target_node, automatic_reboot,
				// skip_ipv4, skip_ipv6, vcpus -- rc5 simply does not populate
				// on import, target_node included, even though the resource id
				// carries the node.  Adopting a VM therefore leaves those to
				// be filled in from configuration on the next plan.  Recorded
				// rather than fixed: changing what import writes is a state
				// change, and the drop-in release must not make one.
				ImportStateVerifyIgnore: []string{
					"additional_wait",
					"agent_timeout",
					"automatic_reboot",
					"clone_wait",
					"define_connection_info",
					"force_create",
					"full_clone",
					"pxe",
					"skip_ipv4",
					"skip_ipv6",
					"ssh_forward_ip",
					"ssh_private_key",
					"ssh_user",
					"target_node",
					"timeouts",
					"vcpus",
				},
			},
		},
	})
}

// TestAccForkVmQemu_UpdateInPlace changes the attributes that get changed in
// practice and requires the VM to survive.  A recreate here would mean a
// routine resize rebuilds the machine.
//
// It runs against a stopped VM, and that is a property of the environment
// rather than of the provider.  rebootRequired comes back from
// config.Update() (resource_vm_qemu.go:1004), and for a running VM the API
// library performs the powerdown itself -- before the provider's fallback
// that force stops on failure, so there is no recovery.  These VMs PXE boot
// with no OS installed, so nothing answers ACPI and the update dies with
// "VM quit/powerdown failed - got timeout" after about three and a half
// minutes.  Stopped, the update applies directly and cores, memory and tags
// can all be exercised.
//
// Not covered, therefore: an in-place update of a *running* VM that requires
// a reboot.  That needs a guest which can shut itself down, so it needs a
// real OS in the image.
func TestAccForkVmQemu_UpdateInPlace(t *testing.T) {
	name := forkVMName()
	before := forkBaseVM(name)
	before.VMState = "stopped"
	after := forkBaseVM(name)
	after.VMState = "stopped"
	after.Cores = 4
	after.Memory = 4096
	after.Balloon = 4096
	after.Tags = "acctest;updated"

	var vmID int

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		CheckDestroy:      forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{
				Config: before.hcl(),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists(forkVMResource),
					forkRecordVMID(forkVMResource, &vmID),
					resource.TestCheckResourceAttr(forkVMResource, "cores", "2"),
					resource.TestCheckResourceAttr(forkVMResource, "memory", "2048"),
				),
			},
			{
				Config: after.hcl(),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMIDUnchanged(forkVMResource, &vmID),
					resource.TestCheckResourceAttr(forkVMResource, "cores", "4"),
					resource.TestCheckResourceAttr(forkVMResource, "memory", "4096"),
					resource.TestCheckResourceAttr(forkVMResource, "tags", "acctest;updated"),
				),
			},
		},
	})
}

// TestAccForkVmQemu_TagsAreOrderInsensitive pins the DiffSuppressFunc in
// Internal/pxapi/guest/tags: tags are sorted and deduplicated before
// comparison, so a differently ordered list is not a change.  Real
// configurations do not keep their tags sorted, so losing this suppression
// would produce a permanent diff on a large share of the fleet.
func TestAccForkVmQemu_TagsAreOrderInsensitive(t *testing.T) {
	name := forkVMName()
	sorted := forkBaseVM(name)
	sorted.Tags = "alpha;beta;gamma"
	shuffled := forkBaseVM(name)
	shuffled.Tags = "gamma;alpha;beta"

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		CheckDestroy:      forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{Config: sorted.hcl()},
			{
				// Same tags, different order: this must not be a change.
				Config:   shuffled.hcl(),
				PlanOnly: true,
			},
		},
	})
}

// TestAccForkVmQemu_StoppedState covers vm_state = stopped, which a minority
// of real VMs use.  The provider must create the VM without starting it.
func TestAccForkVmQemu_StoppedState(t *testing.T) {
	name := forkVMName()
	stopped := forkBaseVM(name)
	stopped.VMState = "stopped"
	started := forkBaseVM(name)
	started.VMState = "running"

	var vmID int

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		CheckDestroy:      forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{
				Config: stopped.hcl(),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists(forkVMResource),
					forkRecordVMID(forkVMResource, &vmID),
					resource.TestCheckResourceAttr(forkVMResource, "vm_state", "stopped"),
				),
			},
			{
				Config: started.hcl(),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMIDUnchanged(forkVMResource, &vmID),
					resource.TestCheckResourceAttr(forkVMResource, "vm_state", "running"),
				),
			},
		},
	})
}

// TestAccForkVmQemu_HighAvailability covers hastate and hagroup, which are the
// most used non-default attributes in the configurations this provider serves
// -- 69 of 70 guests in the state profiled for this suite set hastate, and 65
// set hagroup -- and which nothing else here touches.
//
// It needs a quorate cluster, so the test image creates a single node one on
// first boot (see test/acceptance/guest/pve-test-bootstrap.sh). Nothing fails
// over with one node, but every API call the provider makes is the same.
//
// Two things are under test, and the second is the interesting one:
//
//   - the HA resource is really registered with the cluster, checked against
//     the API rather than against state, because the provider writes hastate
//     and hagroup from configuration during create and state would agree with
//     itself either way;
//   - re-planning the same configuration produces no diff. rc5 never calls
//     ReadVMHA, so vmr.HaState() and vmr.HaGroup() are only populated by the
//     create or update that just ran -- a later refresh in a fresh process may
//     read both back empty and show a permanent diff on every HA guest.
//     Upstream added the missing call in 998a5f5, months after rc5.
func TestAccForkVmQemu_HighAvailability(t *testing.T) {
	cfg := forkBaseVM(forkVMName())
	cfg.HAState = "started"
	cfg.HAGroup = forkHAGroup()

	resource.Test(t, resource.TestCase{
		PreCheck:          func() { forkPreCheck(t) },
		ProviderFactories: forkProviderFactories(),
		CheckDestroy:      forkCheckVMsDestroyed,
		Steps: []resource.TestStep{
			{
				Config: cfg.hcl(),
				Check: resource.ComposeTestCheckFunc(
					forkCheckVMExists(forkVMResource),
					forkCheckHAResource(forkVMResource, cfg.HAGroup),
					resource.TestCheckResourceAttr(forkVMResource, "hastate", "started"),
					resource.TestCheckResourceAttr(forkVMResource, "hagroup", cfg.HAGroup),
				),
			},
			{
				// The regression net: if the read path does not repopulate
				// hastate and hagroup, this is where it shows.
				Config:   cfg.hcl(),
				PlanOnly: true,
			},
		},
	})
}
