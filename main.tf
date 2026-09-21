data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  name = join("-", compact([var.prefix, "route53"]))

  # The lambda module runs for_each over custom_iam_policy_arns, so the ARN has
  # to be known at plan time or a first apply fails with "Invalid for_each
  # argument". The policy name is known, and referencing it keeps the
  # dependency edge that orders the attachment after the policy.
  iam_policy_arn_prefix = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy"
  backup_policy_arn     = "${local.iam_policy_arn_prefix}/${aws_iam_policy.backup.name}"
  restore_policy_arn    = "${local.iam_policy_arn_prefix}/${one(aws_iam_policy.restore[*].name)}"

  # rate() is picky about the plural, rate(1 minutes) is rejected by EventBridge.
  rate_expression     = "rate(${var.interval} ${var.interval == 1 ? "minute" : "minutes"})"
  schedule_expression = coalesce(var.schedule_expression, local.rate_expression)

  # Twice the backup interval, so a single missed run does not page anyone.
  missing_backup_period = coalesce(
    var.missing_backup_alarm_period,
    var.schedule_expression != null ? 86400 : min(86400, max(60, var.interval * 120))
  )

  dlq_arn = one(aws_sqs_queue.dlq[*].arn)

  lambda_environment = {
    S3_BUCKET_NAME = module.s3_bucket.bucket_id
    LOG_LEVEL      = var.log_level
  }
}

data "archive_file" "route53_utils" {
  type        = "zip"
  output_path = "${path.module}/route53_code.zip"
  source_dir  = "${path.module}/code"
  excludes    = ["__pycache__", "*.pyc"]
}

# ---------------------------------------------------------------------------
# Backup bucket
# ---------------------------------------------------------------------------

module "s3_bucket" {
  source  = "cloudposse/s3-bucket/aws"
  version = "4.9.0"

  name               = "${local.name}-backups"
  acl                = "private"
  enabled            = true
  user_enabled       = false
  versioning_enabled = true
  tags               = var.tags
  force_destroy      = var.empty_bucket

  allow_encrypted_uploads_only = false
  allow_ssl_requests_only      = var.ssl_requests_only
  minimum_tls_version          = "1.2"

  sse_algorithm      = var.kms_key_arn == null ? "AES256" : "aws:kms"
  kms_master_key_arn = var.kms_key_arn == null ? "" : var.kms_key_arn
  bucket_key_enabled = var.kms_key_arn != null

  object_lock_configuration = var.object_lock_mode == null ? null : {
    mode  = var.object_lock_mode
    days  = coalesce(var.object_lock_days, var.retention_period)
    years = null
  }

  lifecycle_configuration_rules = [
    {
      id      = "expire-backups"
      enabled = true

      abort_incomplete_multipart_upload_days = 7

      expiration = {
        days = var.retention_period
      }
      noncurrent_version_expiration = {
        noncurrent_days = var.retention_period
      }
    }
  ]
}

# ---------------------------------------------------------------------------
# Dead letter queue
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  count = var.dlq_enabled ? 1 : 0

  name                      = "${local.name}-backup-dlq"
  message_retention_seconds = 1209600 # 14 days, the SQS maximum
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

# ---------------------------------------------------------------------------
# Backup lambda
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "backup" {
  statement {
    sid    = "WriteBackupsToS3"
    effect = "Allow"

    actions = [
      "s3:PutObject"
    ]

    resources = [
      "${module.s3_bucket.bucket_arn}/*"
    ]
  }

  statement {
    sid    = "ReadRoute53"
    effect = "Allow"

    actions = [
      "route53:GetHostedZone",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:ListHealthChecks",
      "route53:ListTagsForResource",
      "route53:ListTagsForResources"
    ]

    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]

    content {
      sid       = "EncryptBackups"
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey", "kms:Encrypt", "kms:DescribeKey"]
      resources = [statement.value]
    }
  }

  dynamic "statement" {
    for_each = local.dlq_arn == null ? [] : [local.dlq_arn]

    content {
      sid       = "WriteToDeadLetterQueue"
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_policy" "backup" {
  name        = "${local.name}-backup-policy"
  description = "Route53 Backup Policy"
  policy      = data.aws_iam_policy_document.backup.json
  tags        = var.tags
}

module "backup" {
  source  = "cloudposse/lambda-function/aws"
  version = "0.6.1"

  filename                          = data.archive_file.route53_utils.output_path
  function_name                     = "${local.name}-backup"
  description                       = "Backs up every Route53 hosted zone and health check to S3"
  handler                           = "route53_backup.handle"
  runtime                           = var.python_runtime
  timeout                           = var.backup_timeout
  memory_size                       = var.backup_memory_size
  tags                              = var.tags
  source_code_hash                  = data.archive_file.route53_utils.output_base64sha256
  cloudwatch_logs_retention_in_days = var.log_retention_days
  dead_letter_config_target_arn     = local.dlq_arn

  lambda_environment = {
    variables = local.lambda_environment
  }
  custom_iam_policy_arns = [local.backup_policy_arn]
}

module "backup_events" {
  source          = "./cloud_event_rules"
  name            = "${local.name}-events"
  lambda_arn      = module.backup.arn
  lambda_name     = module.backup.function_name
  dead_letter_arn = local.dlq_arn
  tags            = var.tags

  rules = [
    {
      name                = "timed-exec"
      description         = "Runs the Route53 backup on ${local.schedule_expression}"
      schedule_expression = local.schedule_expression
    }
  ]
}

data "aws_iam_policy_document" "dlq" {
  count = var.dlq_enabled ? 1 : 0

  statement {
    sid    = "AllowEventBridgeToSendToDeadLetterQueue"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq[0].arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = module.backup_events.arns
    }
  }
}

resource "aws_sqs_queue_policy" "dlq" {
  count = var.dlq_enabled ? 1 : 0

  queue_url = aws_sqs_queue.dlq[0].url
  policy    = data.aws_iam_policy_document.dlq[0].json
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "backup_failed" {
  count = var.alarms_enabled ? 1 : 0

  alarm_name        = "${local.name}-backup-failed"
  alarm_description = "The Route53 backup lambda ${module.backup.function_name} returned an error."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions  = { FunctionName = module.backup.function_name }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions
  tags          = var.tags
}

# A backup system that quietly stops running is worse than one that fails
# loudly, so alarm on the absence of invocations as well as on errors.
resource "aws_cloudwatch_metric_alarm" "backup_missing" {
  count = var.alarms_enabled ? 1 : 0

  alarm_name        = "${local.name}-backup-missing"
  alarm_description = "No Route53 backup ran in the last ${local.missing_backup_period} seconds."

  namespace   = "AWS/Lambda"
  metric_name = "Invocations"
  dimensions  = { FunctionName = module.backup.function_name }

  statistic           = "Sum"
  period              = local.missing_backup_period
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions
  tags          = var.tags
}

# ---------------------------------------------------------------------------
# Restore lambda
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "restore" {
  statement {
    sid    = "ReadBackupsFromS3"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion"
    ]

    resources = [
      "${module.s3_bucket.bucket_arn}/*"
    ]
  }

  # Without ListBucket, S3 answers AccessDenied instead of NoSuchKey for a
  # missing object, which hides the fallback to the legacy backup layout.
  statement {
    sid    = "ListBackupBucket"
    effect = "Allow"

    actions = [
      "s3:ListBucket"
    ]

    resources = [
      module.s3_bucket.bucket_arn
    ]
  }

  statement {
    sid    = "RestoreRoute53"
    effect = "Allow"

    actions = [
      "route53:GetHostedZone",
      "route53:GetChange",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:ListHealthChecks",
      "route53:CreateHostedZone",
      "route53:ChangeResourceRecordSets",
      "route53:CreateHealthCheck",
      "route53:AssociateVPCWithHostedZone",
      "route53:ChangeTagsForResource"
    ]

    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]

    content {
      sid       = "DecryptBackups"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:DescribeKey"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_policy" "restore" {
  count = var.enable_restore ? 1 : 0

  name        = "${local.name}-restore-policy"
  description = "Route53 Restore Policy"
  policy      = data.aws_iam_policy_document.restore.json
  tags        = var.tags
}

module "restore" {
  count = var.enable_restore ? 1 : 0

  source  = "cloudposse/lambda-function/aws"
  version = "0.6.1"

  filename                          = data.archive_file.route53_utils.output_path
  function_name                     = "${local.name}-restore"
  description                       = "Restores Route53 hosted zones and health checks from an S3 backup"
  handler                           = "route53_restore.handle"
  runtime                           = var.python_runtime
  timeout                           = var.restore_timeout
  memory_size                       = var.restore_memory_size
  tags                              = var.tags
  source_code_hash                  = data.archive_file.route53_utils.output_base64sha256
  cloudwatch_logs_retention_in_days = var.log_retention_days

  lambda_environment = {
    variables = local.lambda_environment
  }
  custom_iam_policy_arns = [local.restore_policy_arn]
}
