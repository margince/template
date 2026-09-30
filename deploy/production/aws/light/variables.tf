# The variables shared with the Azure light stack come first, with the same
# names. AWS-only variables follow. removed.tf refuses the variables of the
# earlier design.

# ---- Shared with azure/light ----------------------------------------------------

variable "name_prefix" {
  description = "Short prefix for resource names."
  type        = string
  default     = "margince-light"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name_prefix))
    error_message = "name_prefix: 3-31 characters, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "region" {
  description = "AWS region, for example eu-central-1."
  type        = string
  default     = "eu-central-1"
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region))
    error_message = "region must be an AWS region name such as eu-central-1."
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

variable "instance_type" {
  description = "EC2 instance type. t3.large (2 vCPU, 8 GiB) runs api, worker, web, Postgres, Redis and Caddy. Must match cpu_architecture."
  type        = string
  default     = "t3.large"
  validation {
    condition     = var.cpu_architecture != "x86_64" || !can(regex("^(a1|[a-z]+[0-9]+g[a-z]*)\\.", var.instance_type))
    error_message = "instance_type is a Graviton (arm64) type; set cpu_architecture = \"arm64\" or pick an x86_64 instance type."
  }
  validation {
    condition     = var.cpu_architecture != "arm64" || can(regex("^(a1|[a-z]+[0-9]+g[a-z]*)\\.", var.instance_type))
    error_message = "instance_type is not a Graviton (arm64) type such as t4g.large; set cpu_architecture = \"x86_64\" or pick an arm64 instance type."
  }
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key of the ubuntu user, ed25519 or RSA. The host adapter connects with the matching private key."
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
  description = "Root volume size. Docker data is on the data volume."
  type        = number
  default     = 30
  validation {
    condition     = var.os_disk_gb >= 10
    error_message = "os_disk_gb must be at least 10."
  }
}

variable "data_disk_gb" {
  description = "Data volume mounted at /var/lib/docker: the postgres, redis, blobs and caddy volumes, and the images."
  type        = number
  default     = 64
  validation {
    condition     = var.data_disk_gb >= 16
    error_message = "data_disk_gb must be at least 16."
  }
}

variable "enable_backup" {
  description = "Daily EBS snapshots of the data volume and the root volume (Data Lifecycle Manager), 7-day retention. The data volume holds the database and the files and has no other copy."
  type        = bool
  default     = true
}

variable "enable_alarms" {
  description = "CloudWatch alarms: system status check with auto-recover, instance status check for 5 minutes, CPU over 90% for 15 minutes. Sent to an SNS topic and alert_email."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Optional email address subscribed to the alerts topic. Empty adds no subscription. AWS sends a confirmation link first."
  type        = string
  default     = ""
  validation {
    condition     = var.alert_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be empty or a single email address."
  }
}

variable "license_token" {
  description = "MARGINCE_LICENSE. Stored as an SSM SecureString for make deploy. Empty stores nothing; the environment then needs MARGINCE_ENV=test (docs/deploy.md Section 5.8)."
  type        = string
  default     = ""
  sensitive   = true
}

# ---- AWS only -------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block of the VPC. The public subnet is its first /24."
  type        = string
  default     = "10.30.0.0/16"
}

variable "cpu_architecture" {
  description = "x86_64 or arm64. The release images must exist for it: release.yml builds the repository variable PLATFORMS, default linux/amd64. For arm64 (t4g.large), set PLATFORMS to linux/amd64,linux/arm64 before make release."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.cpu_architecture)
    error_message = "cpu_architecture must be \"x86_64\" or \"arm64\"."
  }
}
