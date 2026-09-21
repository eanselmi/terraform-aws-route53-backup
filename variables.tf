variable "prefix" {
  type        = string
  description = <<-DOC
    Prefix for every resource this module creates. The S3 bucket is named
    `{prefix}-route53-backups`, so it has to be globally unique.
  DOC

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,36}[a-z0-9]$", var.prefix))
    error_message = "prefix must be 2-38 lowercase alphanumeric characters or hyphens, and cannot start or end with a hyphen."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates"
  default     = {}
}

# ---------------------------------------------------------------------------
# Schedule
# ---------------------------------------------------------------------------

variable "interval" {
  type        = number
  description = "Interval (in minutes) of the scheduled backup. Ignored when `schedule_expression` is set"
  default     = 120

  validation {
    condition     = var.interval >= 1 && floor(var.interval) == var.interval
    error_message = "interval must be a whole number of minutes, at least 1."
  }
}

variable "schedule_expression" {
  type        = string
  description = "EventBridge schedule expression for the backup, e.g. `cron(0 3 * * ? *)`. Overrides `interval`"
  default     = null

  validation {
    condition     = var.schedule_expression == null || can(regex("^(rate|cron)\\(.+\\)$", var.schedule_expression))
    error_message = "schedule_expression must be a rate(...) or cron(...) expression."
  }
}

# ---------------------------------------------------------------------------
# Lambdas
# ---------------------------------------------------------------------------

variable "enable_restore" {
  type        = bool
  description = "Deploy the restore lambda. It is never scheduled, only invoked by hand"
  default     = true
}

variable "python_runtime" {
  type        = string
  description = "Python runtime of the backup/restore lambdas"
  default     = "python3.12"

  validation {
    condition     = can(regex("^python3\\.\\d+$", var.python_runtime))
    error_message = "python_runtime must look like python3.12."
  }
}

variable "backup_timeout" {
  type        = number
  description = "Backup lambda timeout (in seconds)"
  default     = 300

  validation {
    condition     = var.backup_timeout >= 1 && var.backup_timeout <= 900
    error_message = "backup_timeout must be between 1 and 900 seconds."
  }
}

variable "restore_timeout" {
  type        = number
  description = "Restore lambda timeout (in seconds). A restore walks every zone, so it needs room"
  default     = 900

  validation {
    condition     = var.restore_timeout >= 1 && var.restore_timeout <= 900
    error_message = "restore_timeout must be between 1 and 900 seconds."
  }
}

variable "backup_memory_size" {
  type        = number
  description = "Memory (in MB) of the backup lambda. More memory also means more CPU and network throughput"
  default     = 512
}

variable "restore_memory_size" {
  type        = number
  description = "Memory (in MB) of the restore lambda"
  default     = 512
}

variable "log_level" {
  type        = string
  description = "Log level of the lambdas"
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of DEBUG, INFO, WARNING, ERROR."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the lambda CloudWatch log groups. Use 0 to keep the logs forever"
  default     = 30

  validation {
    condition = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365,
    400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention value CloudWatch Logs accepts."
  }
}

# ---------------------------------------------------------------------------
# Bucket
# ---------------------------------------------------------------------------

variable "retention_period" {
  type        = number
  description = "Time (in days) that a backup is kept before it expires"
  default     = 14

  validation {
    condition     = var.retention_period >= 1 && floor(var.retention_period) == var.retention_period
    error_message = "retention_period must be a whole number of days, at least 1."
  }
}

variable "empty_bucket" {
  type        = bool
  description = <<-DOC
    Allow Terraform to delete a non empty S3 bucket.
    **THESE OBJECTS WILL NOT BE RECOVERABLE** even if versioned.
  DOC
  default     = false
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for the backups. Defaults to SSE-S3 (AES256) when unset"
  default     = null
}

variable "ssl_requests_only" {
  type        = bool
  description = "Attach a bucket policy that denies any request not made over TLS"
  default     = true
}

variable "object_lock_mode" {
  type        = string
  description = <<-DOC
    Enable S3 Object Lock on the backup bucket, `GOVERNANCE` or `COMPLIANCE`.
    Object Lock can only be enabled when the bucket is created and cannot be
    turned off afterwards. `COMPLIANCE` makes backups undeletable by anyone,
    including the root user, until the retention expires.
  DOC
  default     = null

  validation {
    condition     = var.object_lock_mode == null || contains(["GOVERNANCE", "COMPLIANCE"], coalesce(var.object_lock_mode, "GOVERNANCE"))
    error_message = "object_lock_mode must be GOVERNANCE, COMPLIANCE or null."
  }
}

variable "object_lock_days" {
  type        = number
  description = "Days a backup object stays locked. Defaults to `retention_period` when Object Lock is enabled"
  default     = null
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------

variable "alarms_enabled" {
  type        = bool
  description = "Create CloudWatch alarms for backup failures and for backups that stop running"
  default     = true
}

variable "alarm_actions" {
  type        = list(string)
  description = "ARNs (usually an SNS topic) notified when a backup alarm fires"
  default     = []
}

variable "dlq_enabled" {
  type        = bool
  description = "Create an SQS dead letter queue for backup invocations that fail every retry"
  default     = true
}

variable "missing_backup_alarm_period" {
  type        = number
  description = <<-DOC
    Window (in seconds) the "no backup ran" alarm looks at. Defaults to twice
    the `interval`, capped at a day. Set it explicitly when you use a custom
    `schedule_expression` that runs less often than daily.
  DOC
  default     = null

  validation {
    condition = var.missing_backup_alarm_period == null || (
      var.missing_backup_alarm_period >= 60
      && var.missing_backup_alarm_period <= 86400
      && var.missing_backup_alarm_period % 60 == 0
    )
    error_message = "missing_backup_alarm_period must be a multiple of 60, between 60 and 86400 seconds."
  }
}
