output "cloud_init" {
  description = "cloud-init document for the VM's custom_data."
  value       = local.cloud_init
}

output "nginx_conf" {
  value = local.nginx_conf
}

output "app_env" {
  value = local.app_env
}

output "secret_env" {
  value = local.secret_env
}

output "vm_files" {
  description = "Files written at first boot, path => permissions."
  value       = { for p, f in local.vm_files : p => f.perm }
}
