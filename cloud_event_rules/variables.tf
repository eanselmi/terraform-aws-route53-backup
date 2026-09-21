variable "rules" {
  type = list(object({
    name                         = string
    description                  = optional(string, "Managed by Terraform")
    schedule_expression          = optional(string)
    event_pattern                = optional(string)
    enabled                      = optional(bool, true)
    input                        = optional(string)
    maximum_retry_attempts       = optional(number)
    maximum_event_age_in_seconds = optional(number)
  }))
  description = <<-DOC
    EventBridge rules that invoke the lambda, along with the permission each one needs.
      name:
        Suffix of the rule name, unique within this module.
      schedule_expression:
        The scheduling expression, e.g. `cron(0 20 * * ? *)` or `rate(5 minutes)`.
        Exactly one of `schedule_expression` or `event_pattern` is required.
      event_pattern:
        The event pattern, as a JSON string.
      description:
        The description of the rule.
      enabled:
        Whether the rule fires. Set to false to pause it without destroying it.
      input:
        Constant JSON passed to the lambda instead of the event.
      maximum_retry_attempts / maximum_event_age_in_seconds:
        Retry policy for failed deliveries to the target.
  DOC
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for rule in var.rules :
      (rule.schedule_expression != null) != (rule.event_pattern != null)
    ])
    error_message = "Each rule needs exactly one of schedule_expression or event_pattern."
  }

  validation {
    condition     = length(distinct([for rule in var.rules : rule.name])) == length(var.rules)
    error_message = "Rule names must be unique."
  }
}

variable "lambda_arn" {
  type        = string
  description = "ARN of the lambda the rules invoke"
}

variable "lambda_name" {
  type        = string
  description = "Function name of the lambda the rules invoke"
}

variable "name" {
  type        = string
  description = "Name prefix of the rules. Together with a rule name it must stay under 64 characters"

  validation {
    condition     = length(var.name) <= 53
    error_message = "name must be at most 53 characters, EventBridge rule names are capped at 64."
  }
}

variable "dead_letter_arn" {
  type        = string
  description = "SQS queue ARN that receives events EventBridge could not deliver to the lambda"
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the rules"
  default     = {}
}
