output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "public_ip" {
  description = "The VM's public IP. Point your hostname's A record here."
  value       = azurerm_public_ip.vm.ip_address
}

output "egress_ip" {
  description = "Outbound address of the VM (same as public_ip). Add it to the Dataverse IP firewall."
  value       = azurerm_public_ip.vm.ip_address
}

output "azure_fqdn" {
  description = "Azure DNS name of the public IP; a CNAME target for your hostname."
  value       = azurerm_public_ip.vm.fqdn
}

output "public_base_url" {
  value = local.public_base_url
}

output "ssh_via_bastion" {
  description = "How to open a shell on the VM."
  value = var.enable_bastion_developer ? join(" ", [
    "Azure portal: VM ${azurerm_linux_virtual_machine.this.name} > Connect > Bastion,",
    "user ${var.admin_username}, your SSH private key.",
    "Or: az vm run-command invoke -g ${azurerm_resource_group.this.name} -n ${azurerm_linux_virtual_machine.this.name} --command-id RunShellScript --scripts '<command>'",
    ]) : join(" ", [
    "Bastion is disabled. az vm run-command invoke -g ${azurerm_resource_group.this.name} -n ${azurerm_linux_virtual_machine.this.name}",
    "--command-id RunShellScript --scripts '<command>'",
  ])
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "admin_password_command" {
  description = "Prints the bootstrap admin password (needs Key Vault access from your IP)."
  value       = "az keyvault secret show --vault-name ${azurerm_key_vault.this.name} -n margince-admin-password --query value -o tsv"
}

output "entra_client_id" {
  value = local.entra_client_id
}

output "entra_tenant_id" {
  value = local.entra_tenant_id
}

output "entra_redirect_uris" {
  description = "Redirect URIs registered on the Entra app (or to register by hand when create_entra_app = false)."
  value       = local.entra_redirect_uris
}
