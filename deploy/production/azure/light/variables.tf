# ---- Placement ----------------------------------------------------------------

variable "azure_region" {
  description = "Azure region short name (e.g. westeurope, germanywestcentral). It is also part of the default hostname <label>.<region>.cloudapp.azure.com."
  type        = string
  default     = "westeurope"
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.azure_region))
    error_message = "azure_region must be the short name without spaces, e.g. westeurope."
  }
}

variable "resource_group_name" {
  description = "Resource group created for every resource in this stack."
  type        = string
  default     = "margince-light"
}

variable "name_prefix" {
  description = "Short prefix for resource names. Globally unique names add a random suffix (naming.tf)."
  type        = string
  default     = "margince"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,12}$", var.name_prefix))
    error_message = "name_prefix: 3-13 characters, lowercase letters, digits and hyphens, starting with a letter (key vault names are limited to 24 characters)."
  }
}

variable "environment" {
  description = "Value of the Environment tag on every resource."
  type        = string
  default     = "poc"
}

variable "vnet_cidr" {
  description = "Address space of the virtual network. The VM and Postgres subnets are the first two /24s."
  type        = string
  default     = "10.30.0.0/16"
}

# ---- Public entry -------------------------------------------------------------

variable "dns_label" {
  description = "DNS label of the public IP (<label>.<region>.cloudapp.azure.com). Empty uses <name_prefix>-<suffix>."
  type        = string
  default     = ""
  validation {
    condition     = var.dns_label == "" || can(regex("^[a-z][a-z0-9-]{1,61}[a-z0-9]$", var.dns_label))
    error_message = "dns_label: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "public_hostname" {
  description = <<-EOT
    Your own hostname for Margince (e.g. crm.example.com). Point an A record
    at the public_ip output (or a CNAME at azure_fqdn), then run
    `sudo margince-enable-tls` on the VM. Empty serves Margince on the Azure
    DNS name, which gets its certificate automatically at first boot.
  EOT
  type        = string
  default     = ""
  validation {
    condition     = var.public_hostname == "" || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.public_hostname))
    error_message = "public_hostname must be a lowercase DNS name without scheme or path."
  }
}

variable "acme_email" {
  description = "Contact address for the Let's Encrypt account (expiry warnings). Empty registers without an address."
  type        = string
  default     = ""
  validation {
    condition     = var.acme_email == "" || can(regex("^[^@\\s'\"]+@[^@\\s'\"]+$", var.acme_email))
    error_message = "acme_email must be a plain email address."
  }
}

variable "break_glass_cidrs" {
  description = <<-EOT
    Source ranges allowed to use password login (POST /v1/auth/login). Every
    other client gets 403 from nginx, so staff sign in through Entra ID where
    Conditional Access applies. Include the address you use for the first
    login with the bootstrap admin. Empty blocks password login for everyone.
  EOT
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.break_glass_cidrs : can(cidrhost(c, 0))])
    error_message = "break_glass_cidrs entries must be CIDR ranges such as 203.0.113.10/32."
  }
}

variable "auth_rate_limit_per_minute" {
  description = "Requests per minute per client address nginx allows on login, password reset, OAuth token and setup paths (burst of the same size)."
  type        = number
  default     = 30
}

# ---- Virtual machine ----------------------------------------------------------

variable "vm_size" {
  description = "VM size. 2 vCPU / 8 GiB builds Margince from source in roughly 15 minutes and then runs api, worker, Redis and nginx."
  type        = string
  default     = "Standard_B2ms"
}

variable "admin_username" {
  type    = string
  default = "margince"
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key for admin_username, RSA (ssh-keygen -t rsa -b 4096) or ed25519. Password login is disabled."
  type        = string
  validation {
    condition     = startswith(var.admin_ssh_public_key, "ssh-ed25519 ") || startswith(var.admin_ssh_public_key, "ssh-rsa ")
    error_message = "admin_ssh_public_key must be an ed25519 or RSA key (ssh-ed25519 ... or ssh-rsa ...); Azure accepts no other type."
  }
}

variable "encryption_at_host" {
  description = "Encrypts the VM's temp disk and disk caches on the host. Needs the subscription feature Microsoft.Compute/EncryptionAtHost registered once (README.md)."
  type        = bool
  default     = true
}

variable "enable_vm_backup" {
  description = "Adds a Recovery Services vault backing up the VM (OS and data disk) daily with 7-day retention. About EUR 8/month."
  type        = bool
  default     = false
}

variable "os_disk_gb" {
  type    = number
  default = 32
}

variable "data_disk_gb" {
  description = "Data disk mounted at /var/lib/margince: attachments, Redis data and the build cache."
  type        = number
  default     = 64
}

variable "data_disk_type" {
  type    = string
  default = "StandardSSD_LRS"
}

variable "enable_bastion_developer" {
  description = "Adds Azure Bastion's free Developer tier for browser SSH to the VM from the Azure portal. SSH is open to Bastion only."
  type        = bool
  default     = true
}

# ---- Margince build -----------------------------------------------------------

variable "margince_git_url" {
  description = "Repository the VM clones and builds."
  type        = string
  default     = "https://github.com/margince/margince"
  validation {
    condition     = can(regex("^https://[^'\"\\s]+$", var.margince_git_url))
    error_message = "margince_git_url must be an https URL without quotes or spaces."
  }
}

variable "margince_git_ref" {
  description = "Branch, tag or commit the VM builds at first boot. Later upgrades: `sudo margince-build <ref>` on the VM."
  type        = string
  default     = "main"
  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.margince_git_ref))
    error_message = "margince_git_ref: letters, digits, dot, underscore, slash and hyphen only."
  }
}

# ---- First-boot workspace (written into margince.yaml once) -------------------

variable "workspace_name" {
  type    = string
  default = "Margince"
  validation {
    condition     = can(regex("^[A-Za-z0-9 ._()-]{1,60}$", var.workspace_name))
    error_message = "workspace_name: up to 60 letters, digits, spaces and . _ ( ) -."
  }
}

variable "workspace_base_currency" {
  description = "ISO 4217 code. Cannot be changed once anything has been converted against it."
  type        = string
  default     = "EUR"
  validation {
    condition     = can(regex("^[A-Z]{3}$", var.workspace_base_currency))
    error_message = "workspace_base_currency must be a three-letter ISO code."
  }
}

variable "workspace_base_language" {
  type    = string
  default = "en"
  validation {
    condition     = contains(["en", "de", "vi"], var.workspace_base_language)
    error_message = "workspace_base_language must be en, de or vi."
  }
}

variable "workspace_timezone" {
  type    = string
  default = "Europe/Berlin"
  validation {
    condition     = can(regex("^[A-Za-z0-9_+/-]+$", var.workspace_timezone))
    error_message = "workspace_timezone must be an IANA name such as Europe/Berlin."
  }
}

variable "bootstrap_admin_email" {
  description = "Email of the first admin, created at first boot. Its password is generated into Key Vault (admin_password_command output)."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s'\"|&]+@[^@\\s'\"|&]+$", var.bootstrap_admin_email))
    error_message = "bootstrap_admin_email must be a plain email address."
  }
}

variable "bootstrap_admin_display_name" {
  type    = string
  default = "Margince Admin"
  validation {
    condition     = can(regex("^[A-Za-z0-9 ._-]{1,60}$", var.bootstrap_admin_display_name))
    error_message = "bootstrap_admin_display_name: up to 60 letters, digits, spaces and . _ -."
  }
}

variable "include_bootstrap_admin" {
  description = "Passes the bootstrap admin password to the api. Set false once the first admin has signed in and changed it."
  type        = bool
  default     = true
}

# ---- Database -----------------------------------------------------------------

variable "db_sku_name" {
  description = "Postgres Flexible Server SKU. B_Standard_B1ms (1 vCPU, 2 GiB) is the cheapest."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "db_storage_mb" {
  type    = number
  default = 32768
}

variable "db_version" {
  type    = string
  default = "16"
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

# ---- Secrets and posture ------------------------------------------------------

variable "license_token" {
  description = "MARGINCE_LICENSE. Required when environment_posture is production."
  type        = string
  default     = ""
  sensitive   = true
}

variable "environment_posture" {
  description = <<-EOT
    "production" requires license_token (the api refuses to boot unlicensed).
    "development" sets MARGINCE_ENV=dev for test installations, which may run
    unlicensed.
  EOT
  type        = string
  default     = "production"
  validation {
    condition     = contains(["production", "development"], var.environment_posture)
    error_message = "environment_posture must be \"production\" or \"development\"."
  }
}

variable "operator_ip_allowlist" {
  description = <<-EOT
    Public IPv4 addresses allowed through the Key Vault firewall besides the
    VM: the addresses you run Terraform (and `az keyvault`) from. The vault
    denies every other network, so Terraform cannot write or refresh the
    secrets from an address not listed here.
  EOT
  type        = list(string)
  validation {
    condition     = length(var.operator_ip_allowlist) > 0
    error_message = "operator_ip_allowlist needs at least the public IP you run Terraform from (curl -s https://ifconfig.me)."
  }
  validation {
    condition     = alltrue([for ip in var.operator_ip_allowlist : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", ip))])
    error_message = "operator_ip_allowlist takes plain IPv4 addresses such as 203.0.113.10."
  }
}

# ---- Entra ID -----------------------------------------------------------------

variable "create_entra_app" {
  description = <<-EOT
    true: entra.tf creates the single-tenant app registration for staff
    sign-in and Graph mail capture, requires assignment on its enterprise
    app, assigns entra_access_group_object_id and stores a client secret in
    Key Vault. false: pass entra_client_id and entra_client_secret of a
    hand-made registration.
  EOT
  type        = bool
  default     = true
}

variable "entra_access_group_object_id" {
  description = "Object ID of the Entra security group allowed to use Margince. Reuse the group that gates the Dataverse environment. Required when create_entra_app is true."
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
  description = "Lifetime of the generated client secret. The first apply after this many days replaces it; then restart the services on the VM."
  type        = number
  default     = 180
}

variable "entra_grant_admin_consent" {
  description = "Grants tenant-wide admin consent for the delegated Graph permissions. Needs Privileged Role Administrator or Global Administrator; otherwise an Entra admin grants it in the portal."
  type        = bool
  default     = false
}
