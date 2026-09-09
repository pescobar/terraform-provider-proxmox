terraform {
  required_providers {
    proxmox = {
      source  = "pescobar/proxmox"
      version = "~> 0.9"
    }
  }
}

# Only the endpoint is set here.  Credentials come from the environment --
# PM_API_TOKEN_ID and PM_API_TOKEN_SECRET, or PM_USER and PM_PASS -- so that
# nothing secret lives in the configuration.
provider "proxmox" {
  pm_api_url      = var.pm_api_url
  pm_tls_insecure = true
}
