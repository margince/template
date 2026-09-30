# The variables shared with the AWS light stack come first, with the same
# names. Azure-only variables follow. removed.tf refuses the variables of the
# earlier design.

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

variable "environment" {
  description = "Value of the Environment tag on every resource."
  type        = string
  default     = "production"
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
  description = "Source ranges allowed to reach SSH (port 22): the addresses that run make host-bootstrap and make deploy. 0.0.0.0/0 needs allow_ssh_from_anywhere = true."
  type        = list(string)
  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs needs at least one range, for example the /32 of the address you deploy from (curl -s https://ifconfig.me)."
  }
  validation {
    condition     = alltrue([for c in var.ssh_allowed_cidrs : can(cidrhost(c, 0)) && can(regex("^[0-9.]+/[0-9]+$", c))])
    error_message = "ssh_allowed_cidrs entries must be IPv4 CIDR ranges such as 203.0.113.10/32."
  }
  validation {
    condition     = var.allow_ssh_from_anywhere || !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "ssh_allowed_cidrs contains 0.0.0.0/0. Set allow_ssh_from_anywhere = true to open SSH to the internet on purpose."
  }
}

variable "allow_ssh_from_anywhere" {
  description = "Allows 0.0.0.0/0 in ssh_allowed_cidrs, for example for GitHub-hosted runners. SSH still needs the private key."
  type        = bool
  default     = false
}

variable "os_disk_gb" {
  description = "OS disk size. Docker data is on the data disk."
  type        = number
  default     = 30
  validation {
    condition     = var.os_disk_gb >= 30
    error_message = "os_disk_gb must be at least 30, the size of the Ubuntu image."
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

variable "enable_backup" {
  description = "Daily Azure Backup of the VM with its data disk, 7-day retention. The data disk holds the database and the files and has no other copy."
  type        = bool
  default     = true
}

variable "enable_alarms" {
  description = "Azure Monitor alerts: VM unavailable for 5 minutes, CPU over 90% for 15 minutes. Sent to the action group and alert_email."
  type        = bool
  default     = true
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

variable "resource_group_name" {
  description = "Resource group created for every resource in this stack."
  type        = string
  default     = "margince-light"
}

variable "vnet_cidr" {
  description = "Address space of the virtual network. The VM subnet is its first /24."
  type        = string
  default     = "10.30.0.0/16"
}

variable "admin_username" {
  description = "The SSH user. It gets passwordless sudo, which make host-bootstrap needs."
  type        = string
  default     = "azureadmin"
  validation {
    condition     = var.admin_username != "margince" && can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_username))
    error_message = "admin_username must be a Linux user name (lowercase letters, digits, _ and -) other than margince."
  }
}

variable "encryption_at_host" {
  description = "Encrypts the temp disk and the disk caches on the host. Needs the subscription feature Microsoft.Compute/EncryptionAtHost (README.md)."
  type        = bool
  default     = true
}

variable "data_disk_type" {
  description = "Storage type of the data disk."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "key_vault_allowed_cidrs" {
  description = "Extra IPv4 ranges allowed through the Key Vault firewall, besides ssh_allowed_cidrs. Terraform writes the secrets and make deploy reads them from these addresses."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.key_vault_allowed_cidrs : can(cidrhost(c, 0)) && can(regex("^[0-9.]+/[0-9]+$", c))])
    error_message = "key_vault_allowed_cidrs entries must be IPv4 CIDR ranges such as 203.0.113.10/32."
  }
}

variable "create_entra_app" {
  description = "true: entra.tf creates the single-tenant app registration for staff sign-in and Graph mail, and stores its client secret in Key Vault. false: pass entra_client_id and entra_client_secret of a hand-made registration."
  type        = bool
  default     = true
}

variable "entra_access_group_object_id" {
  description = "Object ID of the Entra security group allowed to use Margince. Required when create_entra_app is true."
  type        = string
  default     = ""
}

variable "entra_client_id" {
  description = "Client ID of a hand-made app registration. Read only when create_entra_app is false."
  type        = string
  default     = ""
}

variable "entra_client_secret" {
  description = "Client secret of a hand-made app registration. Read only when create_entra_app is false."
  type        = string
  default     = ""
  sensitive   = true
}

variable "entra_secret_rotation_days" {
  description = "Lifetime of the generated client secret. The first apply after this many days replaces it; then run make deploy again."
  type        = number
  default     = 180
}

variable "entra_grant_admin_consent" {
  description = "Grants tenant-wide admin consent for the delegated Graph permissions. Needs Privileged Role Administrator or Global Administrator."
  type        = bool
  default     = false
}
