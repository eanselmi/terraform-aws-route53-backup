output "function_names" {
  value = compact([
    module.backup.function_name,
    join("", module.restore[*].function_name)
  ])
}

output "s3_bucket_name" {
  value = module.s3_bucket.bucket_id
}

output "stack_name" {
  value = "${local.name}-backups"
}
