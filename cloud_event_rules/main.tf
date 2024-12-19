locals {
  rules = { for rule in var.rules : rule.name => rule }
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.rules

  name                = "${var.name}-${each.key}"
  schedule_expression = lookup(each.value, "schedule_expression", null)
  event_pattern       = lookup(each.value, "event_pattern", null)
  description         = lookup(each.value, "description", "Managed by Terraform")
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.rules

  target_id = "${var.name}-${each.key}"
  rule      = aws_cloudwatch_event_rule.this[each.key].name
  arn       = var.lambda_arn
}

resource "aws_lambda_permission" "this" {
  for_each = local.rules

  statement_id  = "${var.name}-${each.key}"
  action        = "lambda:InvokeFunction"
  principal     = "events.amazonaws.com"
  function_name = var.lambda_name
  source_arn    = aws_cloudwatch_event_rule.this[each.key].arn
}