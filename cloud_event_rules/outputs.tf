output "ids" {
  description = "IDs of the CloudWatch event rules, keyed by rule name"
  value       = { for name, rule in aws_cloudwatch_event_rule.this : name => rule.id }
}

output "arns" {
  description = "ARNs of the CloudWatch event rules"
  value       = [for rule in aws_cloudwatch_event_rule.this : rule.arn]
}

output "names" {
  description = "Names of the CloudWatch event rules"
  value       = [for rule in aws_cloudwatch_event_rule.this : rule.name]
}
