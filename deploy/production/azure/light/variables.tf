# The variables shared with the AWS light stack come first, with the same
# names. Azure-only variables follow. Everything else is fixed in the stack.

# ---- Shared with aws/light ----------------------------------------------------

variable "name_prefix" {
  description = "Short prefix for resource names. The key vault name adds a random suffix (naming.tf)."
  type        = string
  default     = "margince"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,12}$", var.name_prefix))
    error_message = "name_prefix: 3-13 characters, lowercase letters, digits and hyphens, starting with a letter (key vault names are limited to 24 characters)."
  }
}

variable "region" {
  description = "Azure region short name, for example westeurope or germanywestcentral."
  type        = string
  default     = "westeurope"
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.region))
    error_message = "region must be the short name without spaces, for example westeurope."
  }
}

variable "domain" {
  description = "The public host name of Margince, for example crm.example.com. It becomes HOST_DOMAIN in deploy/production/host.env. Create its A record for the public_ip output."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain))
    error_message = "domain must be a lowercase DNS name without scheme, port or path, for example crm.example.com."
  }
}

variable "vm_size" {
  description = "VM size. Standard_B2ms (2 vCPU, 8 GiB) runs api, worker, web, Postgres, Redis and Caddy."
  type        = string
  default     = "Standard_B2ms"
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key of the admin user, ed25519 or RSA. The host adapter connects with the matching private key. Password login is disabled."
  type        = string
  validation {
    condition     = startswith(var.admin_ssh_public_key, "ssh-ed25519 ") || startswith(var.admin_ssh_public_key, "ssh-rsa ")
    error_message = "admin_ssh_public_key must be an ed25519 or RSA key (ssh-ed25519 ... or ssh-rsa ...)."
  }
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 ranges allowed to reach SSH (port 22) and the Key Vault firewall: the addresses that run Terraform, make host-bootstrap and make deploy."
  type        = list(string)
  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs needs at least one range, for example the /32 of the address you deploy from (curl -s https://ifconfig.me)."
  }
  validation {
    condition     = alltrue([for c in var.ssh_allowed_cidrs : !endswith(c, "/0")])
    error_message = "ssh_allowed_cidrs must not contain 0.0.0.0/0 or ::/0: SSH is never open to the internet."
  }
  validation {
    condition     = alltrue([for c in var.ssh_allowed_cidrs : can(cidrhost(c, 0)) && can(regex("^[0-9.]+/[0-9]+$", c))])
    error_message = "ssh_allowed_cidrs entries must be IPv4 CIDR ranges such as 203.0.113.10/32."
  }
}

variable "data_disk_gb" {
  description = "Data disk mounted at /var/lib/docker: the postgres, redis, blobs and caddy volumes, and the images."
  type        = number
  default     = 64
  validation {
    condition     = var.data_disk_gb >= 16
    error_message = "data_disk_gb must be at least 16."
  }
}

variable "alert_email" {
  description = "Optional email address that receives the alerts. Empty adds no receiver."
  type        = string
  default     = ""
  validation {
    condition     = var.alert_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be empty or a single email address."
  }
}

variable "license_token" {
  description = "MARGINCE_LICENSE. Stored in Key Vault for make deploy. Empty stores nothing; the environment then needs MARGINCE_ENV=test (docs/deploy.md Section 5.8)."
  type        = string
  default     = ""
  sensitive   = true
}

# ---- Azure only -----------------------------------------------------------------

variable "entra_access_group_object_id" {
  description = "Object ID of the Entra security group allowed to use Margince, usually the group that already gates Dataverse."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.entra_access_group_object_id))
    error_message = "entra_access_group_object_id must be the object ID (a GUID) of the security group that already gates the Dataverse environment."
  }
}
