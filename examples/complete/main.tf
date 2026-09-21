# Everything turned on: a nightly backup kept for three months, encrypted with
# a customer managed key, locked against deletion, and alarms wired to SNS.

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  type        = string
  description = "Has to be globally unique, the S3 bucket is named after it"
}

resource "aws_sns_topic" "alerts" {
  name = "${var.prefix}-route53-backup-alerts"
}

resource "aws_kms_key" "backups" {
  description             = "Route53 backups"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

module "route53_backup" {
  source = "../../"

  prefix = var.prefix

  # One backup a night instead of the default every two hours.
  schedule_expression = "cron(0 3 * * ? *)"

  retention_period   = 90
  log_retention_days = 90

  # Customer managed key, and objects that cannot be deleted before they expire.
  kms_key_arn      = aws_kms_key.backups.arn
  object_lock_mode = "GOVERNANCE"

  # Page someone when a backup fails or simply stops running.
  alarms_enabled = true
  alarm_actions  = [aws_sns_topic.alerts.arn]
  dlq_enabled    = true

  # A nightly schedule needs a wider window than the default.
  missing_backup_alarm_period = 86400

  tags = {
    Environment = "production"
    Service     = "route53-backup"
  }
}

output "backup_function_name" {
  value = module.route53_backup.backup_function_name
}

output "restore_function_name" {
  value = module.route53_backup.restore_function_name
}

output "s3_bucket_name" {
  value = module.route53_backup.s3_bucket_name
}

output "alarm_names" {
  value = module.route53_backup.alarm_names
}
