output "function_names" {
  description = "Names of the lambdas this module created"
  value = compact([
    module.backup.function_name,
    join("", module.restore[*].function_name)
  ])
}

output "backup_function_name" {
  description = "Name of the backup lambda"
  value       = module.backup.function_name
}

output "backup_function_arn" {
  description = "ARN of the backup lambda"
  value       = module.backup.arn
}

output "restore_function_name" {
  description = "Name of the restore lambda, null when `enable_restore` is false"
  value       = one(module.restore[*].function_name)
}

output "restore_function_arn" {
  description = "ARN of the restore lambda, null when `enable_restore` is false"
  value       = one(module.restore[*].arn)
}

output "s3_bucket_name" {
  description = "Name of the bucket holding the backups"
  value       = module.s3_bucket.bucket_id
}

output "s3_bucket_arn" {
  description = "ARN of the bucket holding the backups"
  value       = module.s3_bucket.bucket_arn
}

output "schedule_expression" {
  description = "The EventBridge schedule the backup runs on"
  value       = local.schedule_expression
}

output "event_rule_arns" {
  description = "ARNs of the EventBridge rules invoking the backup"
  value       = module.backup_events.arns
}

output "dead_letter_queue_arn" {
  description = "ARN of the backup dead letter queue, null when `dlq_enabled` is false"
  value       = one(aws_sqs_queue.dlq[*].arn)
}

output "dead_letter_queue_url" {
  description = "URL of the backup dead letter queue, null when `dlq_enabled` is false"
  value       = one(aws_sqs_queue.dlq[*].url)
}

output "alarm_names" {
  description = "Names of the CloudWatch alarms watching the backup"
  value = compact([
    one(aws_cloudwatch_metric_alarm.backup_failed[*].alarm_name),
    one(aws_cloudwatch_metric_alarm.backup_missing[*].alarm_name)
  ])
}
