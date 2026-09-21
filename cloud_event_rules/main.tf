locals {
  rules = { for rule in var.rules : rule.name => rule }
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.rules

  name                = "${var.name}-${each.key}"
  schedule_expression = each.value.schedule_expression
  event_pattern       = each.value.event_pattern
  description         = each.value.description
  state               = each.value.enabled ? "ENABLED" : "DISABLED"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.rules

  target_id = "${var.name}-${each.key}"
  rule      = aws_cloudwatch_event_rule.this[each.key].name
  arn       = var.lambda_arn
  input     = each.value.input

  dynamic "retry_policy" {
    for_each = (each.value.maximum_retry_attempts == null
    && each.value.maximum_event_age_in_seconds == null) ? [] : [each.value]

    content {
      maximum_retry_attempts       = retry_policy.value.maximum_retry_attempts
      maximum_event_age_in_seconds = retry_policy.value.maximum_event_age_in_seconds
    }
  }

  dynamic "dead_letter_config" {
    for_each = var.dead_letter_arn == null ? [] : [var.dead_letter_arn]

    content {
      arn = dead_letter_config.value
    }
  }
}

resource "aws_lambda_permission" "this" {
  for_each = local.rules

  statement_id  = "${var.name}-${each.key}"
  action        = "lambda:InvokeFunction"
  principal     = "events.amazonaws.com"
  function_name = var.lambda_name
  source_arn    = aws_cloudwatch_event_rule.this[each.key].arn
}
