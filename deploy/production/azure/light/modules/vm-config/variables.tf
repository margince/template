variable "key_vault_name" {
  description = "Key Vault the VM reads its secrets from."
  type        = string
}

variable "pg_host" {
  description = "Postgres server FQDN (its TLS certificate must match)."
  type        = string
}

variable "public_host" {
  description = "Host name users reach Margince on."
  type        = string
}

variable "public_base_url" {
  description = "https://<public_host>"
  type        = string
}

variable "azure_fqdn" {
  description = "The VM's Azure DNS name (<label>.<region>.cloudapp.azure.com)."
  type        = string
}

variable "git_url" {
  type = string
}

variable "git_ref" {
  type = string
}

variable "acme_email" {
  type = string
}

variable "workspace_name" {
  type = string
}

variable "workspace_base_currency" {
  type = string
}

variable "workspace_base_language" {
  type = string
}

variable "workspace_timezone" {
  type = string
}

variable "admin_email" {
  type = string
}

variable "admin_display_name" {
  type = string
}

variable "entra_client_id" {
  type = string
}

variable "entra_tenant_id" {
  type = string
}

variable "environment_posture" {
  type = string
}

variable "include_bootstrap_admin" {
  type = bool
}

variable "license_present" {
  description = "Whether a licence secret exists in Key Vault."
  type        = bool
}

variable "break_glass_cidrs" {
  type = list(string)
}

variable "auth_rate_limit_per_minute" {
  type = number
}
