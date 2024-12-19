output "ids" {
  description = "A list of CloudWatch event rule IDs"
  value       = try(values(aws_cloudwatch_event_rule.this)[*]["id"], null)
}

output "arns" {
  description = "A list of CloudWatch event rule ARNs"
  value       = try(values(aws_cloudwatch_event_rule.this)[*]["arn"], null)
}