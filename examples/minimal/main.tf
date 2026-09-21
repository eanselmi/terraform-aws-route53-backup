# The smallest useful deployment: backups every two hours, kept for 14 days.

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

module "route53_backup" {
  source = "../../"

  prefix = var.prefix
}

output "backup_function_name" {
  value = module.route53_backup.backup_function_name
}

output "s3_bucket_name" {
  value = module.route53_backup.s3_bucket_name
}
