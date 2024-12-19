variable "backup_timeout" {
  type        = number
  description = "Timeout (in seconds)"
  default     = 300
}

variable "empty_bucket" {
  type        = bool
  description = "Whether or not to empty the S3 bucket"
  default     = false
}

variable "enable_restore" {
  type        = bool
  description = "Enable the restore lambda"
  default     = true
}

variable "interval" {
  type        = number
  description = "The interval (in minutes) of the scheduled backup"
  default     = 120
}

variable "prefix" {
  type        = string
  description = "The prefix for the S3 bucket name"
}

variable "retention_period" {
  type        = number
  description = "The time (in days) that the backup is stored for"
  default     = 14
}

variable "tags" {
  type        = map(string)
  description = "default tags"
  default     = {}
}