# Seven guests, each declared on its own, which is the shape most existing
# configurations have.  They are PXE booted: something outside Terraform -- a
# provisioning system such as MAAS -- installs the operating system, so there
# is no cloud-init and no clone here.
#
# Two settings matter more than they look:
#
#   hastate                = "started"
#     Registers the guest with the HA manager.  A guest that is not HA managed
#     cannot be named by an HA rule at all; Proxmox rejects the whole rule with
#     "cannot use unmanaged resource(s) vm:NNN".
#
#   define_connection_info = false
#     Defaults to true, and with agent = 1 the provider then waits for a guest
#     agent to answer before finishing the create.  A machine that has not been
#     installed yet never answers, so the apply blocks until the create timeout.
#
# hagroup is deliberately absent.  On Proxmox VE 9 it is rejected outright --
# "invalid parameter 'group': ha groups have been migrated to rules" -- and
# placement is expressed by the rule in ha-rules.tf instead.

locals {
  # Shared by every guest below, so the interesting differences stay visible.
  guest_defaults = {
    target_node = var.target_node
    storage     = var.storage
    bridge      = var.bridge
  }
}

resource "proxmox_vm_qemu" "playground_test" {
  vmid        = 601
  name        = "playground-test"
  target_node = local.guest_defaults.target_node

  pxe                    = true
  boot                   = "order=virtio0;net0"
  define_connection_info = false
  agent                  = 1
  hastate                = "started"

  bios     = "seabios"
  scsihw   = "virtio-scsi-single"
  qemu_os  = "l26"
  onboot   = false
  hotplug  = "cpu,network,disk,usb"
  cpu_type = "host"
  sockets  = 1
  cores    = 2
  memory   = 4096
  balloon  = 4096
  tags     = "playground;dev"

  disks {
    virtio {
      virtio0 {
        disk {
          storage  = local.guest_defaults.storage
          size     = "32G"
          format   = "qcow2"
          backup   = true
          iothread = true
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = local.guest_defaults.bridge
  }
}

resource "proxmox_vm_qemu" "playground_vm01" {
  vmid        = 602
  name        = "playground-vm01"
  target_node = local.guest_defaults.target_node

  pxe                    = true
  boot                   = "order=virtio0;net0"
  define_connection_info = false
  agent                  = 1
  hastate                = "started"

  bios     = "seabios"
  scsihw   = "virtio-scsi-single"
  qemu_os  = "l26"
  onboot   = false
  hotplug  = "cpu,network,disk,usb"
  cpu_type = "host"
  sockets  = 1
  cores    = 4
  memory   = 8192
  balloon  = 8192
  tags     = "playground;dev"

  disks {
    virtio {
      virtio0 {
        disk {
          storage  = local.guest_defaults.storage
          size     = "64G"
          format   = "qcow2"
          backup   = true
          iothread = true
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = local.guest_defaults.bridge
  }
}

resource "proxmox_vm_qemu" "playground_vm02" {
  vmid        = 604
  name        = "playground-vm02"
  target_node = "pve-dev02"

  pxe                    = true
  boot                   = "order=virtio0;net0"
  define_connection_info = false
  agent                  = 1
  hastate                = "started"

  bios     = "seabios"
  scsihw   = "virtio-scsi-single"
  qemu_os  = "l26"
  onboot   = false
  hotplug  = "cpu,network,disk,usb"
  cpu_type = "host"
  sockets  = 1
  cores    = 4
  memory   = 8192
  balloon  = 8192
  tags     = "playground;dev"

  disks {
    virtio {
      virtio0 {
        disk {
          storage  = local.guest_defaults.storage
          size     = "64G"
          format   = "qcow2"
          backup   = true
          iothread = true
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = local.guest_defaults.bridge
  }
}

resource "proxmox_vm_qemu" "playground_vm03" {
  vmid        = 605
  name        = "playground-vm03"
  target_node = "pve-dev03"

  pxe                    = true
  boot                   = "order=virtio0;net0"
  define_connection_info = false
  agent                  = 1
  hastate                = "started"

  bios     = "seabios"
  scsihw   = "virtio-scsi-single"
  qemu_os  = "l26"
  onboot   = false
  hotplug  = "cpu,network,disk,usb"
  cpu_type = "host"
  sockets  = 1
  cores    = 2
  memory   = 4096
  balloon  = 4096
  tags     = "playground;dev"

  disks {
    virtio {
      virtio0 {
        disk {
          storage  = local.guest_defaults.storage
          size     = "32G"
          format   = "qcow2"
          backup   = true
          iothread = true
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = local.guest_defaults.bridge
  }
}

resource "proxmox_vm_qemu" "playground_johndoe01" {
  vmid        = 608
  name        = "playground-johndoe01"
  target_node = local.guest_defaults.target_node

  pxe                    = true
  boot                   = "order=virtio0;net0"
  define_connection_info = false
  agent                  = 1
  hastate                = "started"

  bios     = "seabios"
  scsihw   = "virtio-scsi-single"
  qemu_os  = "l26"
  onboot   = false
  hotplug  = "cpu,network,disk,usb"
  cpu_type = "host"
  sockets  = 1
  cores    = 2
  memory   = 4096
  balloon  = 4096
  tags     = "playground;dev;johndoe"

  disks {
    virtio {
      virtio0 {
        disk {
          storage  = local.guest_defaults.storage
          size     = "32G"
          format   = "qcow2"
          backup   = true
          iothread = true
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = local.guest_defaults.bridge
  }
}

resource "proxmox_vm_qemu" "playground_johndoe02" {
  vmid        = 609
  name        = "playground-johndoe02"
  target_node = "pve-dev02"

  pxe                    = true
  boot                   = "order=virtio0;net0"
  define_connection_info = false
  agent                  = 1
  hastate                = "started"

  bios     = "seabios"
  scsihw   = "virtio-scsi-single"
  qemu_os  = "l26"
  onboot   = false
  hotplug  = "cpu,network,disk,usb"
  cpu_type = "host"
  sockets  = 1
  cores    = 2
  memory   = 4096
  balloon  = 4096
  tags     = "playground;dev;johndoe"

  disks {
    virtio {
      virtio0 {
        disk {
          storage  = local.guest_defaults.storage
          size     = "32G"
          format   = "qcow2"
          backup   = true
          iothread = true
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = local.guest_defaults.bridge
  }
}

resource "proxmox_vm_qemu" "playground_johndoe03" {
  vmid        = 610
  name        = "playground-johndoe03"
  target_node = "pve-dev03"

  pxe                    = true
  boot                   = "order=virtio0;net0"
  define_connection_info = false
  agent                  = 1
  hastate                = "started"

  bios     = "seabios"
  scsihw   = "virtio-scsi-single"
  qemu_os  = "l26"
  onboot   = false
  hotplug  = "cpu,network,disk,usb"
  cpu_type = "host"
  sockets  = 1
  cores    = 2
  memory   = 4096
  balloon  = 4096
  tags     = "playground;dev;johndoe"

  disks {
    virtio {
      virtio0 {
        disk {
          storage  = local.guest_defaults.storage
          size     = "32G"
          format   = "qcow2"
          backup   = true
          iothread = true
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = local.guest_defaults.bridge
  }
}
