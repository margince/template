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
  description = "SNS topic every alarm (alarms.tf) notifies. Empty when enable_alarms is false."
  value       = var.enable_alarms ? aws_sns_topic.alerts[0].arn : ""
}

output "secret_parameter_names" {
  description = <<-EOT
    SSM Parameter Store names (not values) of every credential this stack
    seals, SecureString under alias/aws/ssm. Read one with:
      aws ssm get-parameter --name <name> --with-decryption --query Parameter.Value --output text
  EOT
  value       = { for k, p in aws_ssm_parameter.secret : k => p.name }
}
