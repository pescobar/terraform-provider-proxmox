variable "pm_api_url" {
  description = "Proxmox VE API endpoint, including /api2/json."
  type        = string
  default     = "https://pve-dev01.example.org:8006/api2/json"
}

variable "target_node" {
  description = "Node the guests are created on unless a guest overrides it."
  type        = string
  default     = "pve-dev01"
}

variable "storage" {
  description = "Storage for the guests' disks. It must accept disk images."
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Network bridge the guests attach to."
  type        = string
  default     = "vmbr0"
}
