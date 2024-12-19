locals {
  python_runtime = "python3.8"
  name           = join("-", compact([var.prefix, "route53"]))

  policy_arn_prefix = format(
    "arn:%s:iam::%s:policy",
    join("", data.aws_partition.current[*].partition),
    join("", data.aws_caller_identity.current[*].account_id),
  )
  policy_backup_name  = "${local.name}-backup-policy"
  policy_restore_name = "${local.name}-restore-policy"
}

data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "archive_file" "route53_utils" {
  type        = "zip"
  output_path = "route53_code.zip"
  source_dir  = "${path.module}/code"
}

module "s3_bucket" {
  source             = "cloudposse/s3-bucket/aws"
  version            = "1.0.0"
  name               = "${local.name}-backups"
  acl                = "private"
  enabled            = true
  user_enabled       = false
  versioning_enabled = true
  tags               = var.tags
  force_destroy      = var.empty_bucket

  # Don't enable this as the script won't be able to upload
  allow_encrypted_uploads_only = false

  lifecycle_rule_ids = [
    "S3 Deletion Rule"
  ]
  lifecycle_rules = [
    {
      prefix                                         = null
      enabled                                        = true
      tags                                           = var.tags
      enable_glacier_transition                      = false
      enable_deeparchive_transition                  = false
      enable_standard_ia_transition                  = false
      enable_current_object_expiration               = true
      enable_noncurrent_version_expiration           = true
      abort_incomplete_multipart_upload_days         = null
      noncurrent_version_glacier_transition_days     = 0
      noncurrent_version_deeparchive_transition_days = 0
      noncurrent_version_expiration_days             = var.retention_period
      standard_transition_days                       = 0
      glacier_transition_days                        = 0
      deeparchive_transition_days                    = 0
      expiration_days                                = var.retention_period
    }
  ]
}

data "aws_iam_policy_document" "backup" {
  statement {
    sid = "1"

    actions = [
      "s3:PutEncryptionConfiguration",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:PutObjectVersionAcl",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPolicy",
      "s3:CreateBucket",
      "s3:ListBucket",
      "s3:PutBucketVersioning"
    ]

    resources = [
      module.s3_bucket.bucket_arn,
      "${module.s3_bucket.bucket_arn}/*"
    ]
  }
  statement {
    sid = "2"

    actions = [
      "route53:GetHealthCheck",
      "route53:ListHealthChecks",
      "route53:GetHostedZone",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
      "route53:ListTagsForResources"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "backup" {
  name        = local.policy_backup_name
  description = "Route53 Backup Policy"
  policy      = data.aws_iam_policy_document.backup.json
}

module "backup" {
  source           = "cloudposse/lambda-function/aws"
  version          = "0.4.1"
  filename         = data.archive_file.route53_utils.output_path
  function_name    = "${local.name}-backup"
  handler          = "route53_backup.handle"
  runtime          = local.python_runtime
  timeout          = var.backup_timeout
  tags             = var.tags
  source_code_hash = data.archive_file.route53_utils.output_base64sha256

  lambda_environment = {
    variables = {
      S3_BUCKET_NAME = module.s3_bucket.bucket_id
      REGION         = data.aws_region.current.name
    }
  }
  custom_iam_policy_arns = [
    join("/", [local.policy_arn_prefix, local.policy_backup_name])
  ]
  depends_on = [aws_iam_policy.backup]
}

module "backup_events" {
  source      = "./_cloud_event_rules"
  name        = "${local.name}-events"
  lambda_arn  = module.backup.arn
  lambda_name = module.backup.function_name
  tags        = var.tags

  rules = [
    {
      name                = "timed-exec"
      description         = "Fires every ${var.interval} minutes"
      schedule_expression = "rate(${var.interval} minutes)"
    }
  ]
}

data "aws_iam_policy_document" "restore" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject"
    ]
    resources = [
      module.s3_bucket.bucket_arn,
      "${module.s3_bucket.bucket_arn}/*"
    ]
  }
  statement {
    effect = "Allow"

    actions = [
      "route53:GetHealthCheck",
      "route53:ListHealthChecks",
      "route53:GetHostedZone",
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
      "route53:ListTagsForResources",
      "route53:CreateHostedZone",
      "route53:GetHealthCheck",
      "route53:ChangeResourceRecordSets",
      "route53:ListTagsForResource",
      "route53:ListTagsForResources",
      "route53:CreateHealthCheck",
      "route53:AssociateVPCWithHostedZone",
      "route53:ChangeTagsForResource",
      "ec2:DescribeVpcs",
    ]
    resources = [
      "*"
    ]
  }
}

resource "aws_iam_policy" "restore" {
  count = var.enable_restore ? 1 : 0

  name        = local.policy_restore_name
  description = "Route53 Restore Policy"
  policy      = data.aws_iam_policy_document.restore.json
}

module "restore" {
  count = var.enable_restore ? 1 : 0

  source           = "cloudposse/lambda-function/aws"
  version          = "0.4.1"
  filename         = data.archive_file.route53_utils.output_path
  function_name    = "${local.name}-restore"
  handler          = "route53_restore.handle"
  runtime          = local.python_runtime
  tags             = var.tags
  source_code_hash = data.archive_file.route53_utils.output_base64sha256

  lambda_environment = {
    variables = {
      S3_BUCKET_NAME = module.s3_bucket.bucket_id
      REGION         = data.aws_region.current.name
    }
  }
  custom_iam_policy_arns = [
    join("/", [local.policy_arn_prefix, local.policy_restore_name])
  ]
  depends_on = [aws_iam_policy.restore]
}