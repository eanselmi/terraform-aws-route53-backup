variable "rules" {
  type        = list(any)
  description = <<-DOC
    A list of CloudWatch Events rules for invoking the Lambda Function along with the required permissions.
      name:
        The name of the rule.
      schedule_expression:
        The scheduling expression. For example, `cron(0 20 * * ? *)` or `rate(5 minutes)`.
        At least one of `schedule_expression` or `event_pattern` is required.
      event_pattern:
        The event pattern described a JSON object.
      description:
        The description of the rule.
  DOC
  default     = []
}

variable "lambda_arn" {
  type        = string
  description = "ARN of the lambda"
}

variable "lambda_name" {
  type        = string
  description = "Function name of the lambda"
}

variable "name" {
  type        = string
  description = "The name of the events"
}

variable "tags" {
  type        = map(string)
  description = "List of tags"
  default     = {}
}
