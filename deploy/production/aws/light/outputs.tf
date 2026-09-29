output "aws_region" {
  value = var.aws_region
}

output "edge_instance_id" {
  value = aws_instance.edge.id
}

output "app_instance_id" {
  value = aws_instance.app.id
}

output "worker_instance_id" {
  value = aws_instance.worker.id
}

output "ssm_connect_command_edge" {
  description = "Shell access — no SSH ingress on any instance's security group (network.tf), by design."
  value       = "aws ssm start-session --target ${aws_instance.edge.id} --region ${var.aws_region}"
}

output "ssm_connect_command_app" {
  value = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}

output "ssm_connect_command_worker" {
  value = "aws ssm start-session --target ${aws_instance.worker.id} --region ${var.aws_region}"
}

output "acm_validation_record" {
  description = <<-EOT
    The DNS record ACM needs to issue the CloudFront certificate — this
    stack has no Route53 integration, so add this CNAME with your own DNS
    provider before applying aws_acm_certificate_validation.this (see
    README). Empty until aws_acm_certificate.this exists.
  EOT
  value = {
    name  = tolist(aws_acm_certificate.this.domain_validation_options)[0].resource_record_name
    type  = tolist(aws_acm_certificate.this.domain_validation_options)[0].resource_record_type
    value = tolist(aws_acm_certificate.this.domain_validation_options)[0].resource_record_value
  }
}

output "cloudfront_domain_name" {
  description = "Point public_base_url's DNS record here (a CNAME, or an ALIAS/ANAME record if your provider supports one at the zone apex)."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "rds_endpoint" {
  value = aws_db_instance.this.address
}

output "s3_blobstore_bucket" {
  value = aws_s3_bucket.blobstore.bucket
}

output "alerts_topic_arn" {
  description = "Empty when var.enable_deep_monitoring is false — there is no topic to subscribe to."
  value       = var.enable_deep_monitoring ? aws_sns_topic.alerts[0].arn : ""
}

output "secret_arns" {
  description = "Secrets Manager ARNs (not values) for every credential this stack seals."
  value = {
    owner_dsn            = aws_secretsmanager_secret.owner_dsn.arn
    app_dsn              = aws_secretsmanager_secret.app_dsn.arn
    redis_password       = aws_secretsmanager_secret.redis_password.arn
    keyvault_root_key    = aws_secretsmanager_secret.keyvault_root_key.arn
    webhook_key          = aws_secretsmanager_secret.webhook_key.arn
    connector_state_key  = aws_secretsmanager_secret.connector_state_key.arn
    admin_password       = aws_secretsmanager_secret.admin_password.arn
    license              = aws_secretsmanager_secret.license.arn
    blobstore_access_key = aws_secretsmanager_secret.blobstore_access_key.arn
    blobstore_secret_key = aws_secretsmanager_secret.blobstore_secret_key.arn
  }
}
