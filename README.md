<!-- markdownlint-disable -->
# terraform-aws-route53-backup [![Latest Release](https://img.shields.io/github/release/eanselmi/terraform-aws-route53-backup.svg)](https://github.com/eanselmi/terraform-aws-route53-backup/releases/latest)
<!-- markdownlint -->

Terraform module for provisioning Route53 backup/restore lambda functions.

![image](https://i.ibb.co/4n9zCFn8/r53-backup.png)

Included Features:
* Versioned, encrypted S3 bucket with lifecycle based retention
* Backup of Route53 hosted zones, record sets, health checks, VPC associations and tags
* Restore capability for all of the above, with a dry run mode
* CloudWatch alarms for a backup that fails *and* for a backup that quietly stops running
* Dead letter queue for invocations that never make it through

## How it works

An EventBridge rule invokes the backup lambda on a schedule. The lambda walks every
hosted zone and health check in the account and writes them to a versioned S3 bucket,
whose lifecycle rule expires the objects after `retention_period` days.

The restore lambda is deployed but never scheduled — it is invoked by hand when you need
it. It reads a backup from the same bucket, recreates any hosted zone that no longer
exists and `UPSERT`s the records that differ from what is live. It never deletes
anything, so restoring is always additive.

```
EventBridge rule ──► backup lambda ──► S3 bucket ◄── restore lambda ──► Route53
  schedule                              versioned      (manual invoke)
       │                                    │
       └──► DLQ (SQS)        CloudWatch alarms on errors and on missing backups
```

## Usage

### Simple example:

```hcl
module "instance" {
    source = "eanselmi/route53-backup/aws"
    # Pin every module to a specific version
    # version     = "x.x.x"
    prefix = "dev"
}
```

### Override the defaults

```hcl
module "instance" {
    source = "eanselmi/route53-backup/aws"
    # Pin every module to a specific version
    # version        = "x.x.x"
    prefix           = "dev"
    retention_period = 5
    interval         = 1440  # once a day, the interval is in minutes
    enable_restore   = false
}
```

Runnable configurations live in [`examples/`](examples): [`minimal`](examples/minimal)
is the four line version, [`complete`](examples/complete) turns on KMS, Object Lock and
SNS alerting.

### Destroying the S3 bucket

You will need to set `empty_bucket = true`, run `terraform apply`, then you can run `terraform destroy`.

## What a backup looks like

Every run writes a new timestamped prefix into the bucket:

```
2024-06-01T12:00:00Z/zones.json          # every hosted zone, with its VPCs and tags
2024-06-01T12:00:00Z/zones/Z1D633PJN98FT9.json   # the record sets of one zone
2024-06-01T12:00:00Z/health-checks.json  # every health check, with its tags
2024-06-01T12:00:00Z/manifest.json       # what the run wrote, for verification
latest_backup_timestamp                  # the prefix the restore defaults to
```

`latest_backup_timestamp` is written last and only once every other object landed, so a
run that fails part way through never becomes the backup a restore picks up. A zone that
is deleted while the backup is running is left out of `zones.json` rather than failing
the whole run; any other error fails loudly so the alarm fires.

Zone records are keyed by hosted zone ID rather than by name, so a public and a private
zone sharing a name (split horizon) do not overwrite each other. Backups written by
earlier versions of this module used the zone name as the key and are still restorable —
the restore lambda falls back to that layout automatically.

## Manually triggering the functions

You can use AWS CLI to trigger either lambda

```shell
# backup
aws lambda invoke --function-name {prefix}-route53-backup --output text /dev/stdout

# restore (all zones, from the most recent backup)
aws lambda invoke --function-name {prefix}-route53-restore --output text /dev/stdout

# restore (single zone by name)
aws lambda invoke --function-name {prefix}-route53-restore --payload '{"names":["example.com"]}' --cli-binary-format raw-in-base64-out --output text /dev/stdout

# restore (single zone by id)
aws lambda invoke --function-name {prefix}-route53-restore --payload '{"ids":["Z750C051B"]}' --cli-binary-format raw-in-base64-out --output text /dev/stdout

# restore (specific backup)
aws lambda invoke --function-name {prefix}-route53-restore --payload '{"from":"2022-12-28T00:00:00Z"}' --cli-binary-format raw-in-base64-out --output text /dev/stdout

# restore (report what would change without touching Route53)
aws lambda invoke --function-name {prefix}-route53-restore --payload '{"dryrun":true}' --cli-binary-format raw-in-base64-out --output text /dev/stdout
```

### Restore event payload

| Key      | Type       | Description                                                                        |
| -------- | ---------- | ---------------------------------------------------------------------------------- |
| `from`   | `string`   | Timestamp of the backup to restore. Defaults to `latest_backup_timestamp`.         |
| `ids`    | `[string]` | Only restore these hosted zones. Accepts `Z750C051B` or `/hostedzone/Z750C051B`.   |
| `names`  | `[string]` | Only restore these hosted zones by name. The trailing dot and casing are optional. |
| `dryrun` | `bool`     | Log what would be restored without calling Route53. Defaults to `false`.           |

`ids` and `names` can be combined, a zone matching either one is restored. Any id or
name that no backup matched is reported in the lambda log, so a typo does not look like
a successful restore. In a split horizon setup a `names` selector matches both the public
and the private zone — use `ids` to pick one of them. Selecting zones does not narrow the
health checks, those are always reconciled in full.

The restore returns a summary of what it did:

```json
{"timestamp": "2024-06-01T12:00:00Z", "dryrun": false, "zones_changed": 2,
 "zones_created": 1, "records": 143, "records_skipped": 0, "health_checks": 1}
```

### What the restore does and does not do

* Records are only ever added or updated, never deleted. A record created after the
  backup was taken stays where it is.
* Health checks are reconciled **before** the zones, and they are matched by their
  configuration rather than by their ID, because a restored health check gets a new one.
  Record sets that referenced the old ID are rewritten to the new one. Re-running the
  restore does not create duplicates.
* A zone is located by ID first and by name second, so a zone that was deleted and
  recreated by hand is reconciled instead of being duplicated. The name lookup only
  matches a zone of the same visibility, so split horizon setups stay separate.
* Large zones are split across as many `ChangeResourceRecordSets` batches as the Route53
  limits require, so a zone with thousands of records restores in one go.
* The `NS` and `SOA` records at the apex of a zone are skipped. A recreated zone gets a
  fresh delegation set from AWS, and restoring the old name servers would break the
  delegation. `NS` records that delegate a subdomain are restored normally.
* **If a zone was recreated, its name servers changed.** Update the delegation at your
  registrar with the new values from the restored zone.
* A private zone is recreated with every VPC association recorded in the backup. Cross
  account associations need to be authorized separately and are logged if they fail. A
  private zone whose backup holds no VPC is skipped, since Route53 cannot create one.
* Tags are restored only on a zone this module had to recreate, so tags added to a live
  zone since the backup are left alone.
* A record pointing at a health check that no longer exists and could not be recreated is
  skipped and counted in `records_skipped`, rather than failing the batch it travels in.
* Records managed by a traffic policy instance lose their `TrafficPolicyInstanceId` on
  restore. Recreate those through the traffic policy instead.
* Alias records pointing at resources in another account or region do not resolve in a
  cross account restore.

## Operating it

* **`{prefix}-route53-backup-failed`** fires when the lambda errors.
* **`{prefix}-route53-backup-missing`** fires when no invocation happened within
  `missing_backup_alarm_period` (twice the `interval` by default, capped at a day). A
  backup system that stops running silently is the failure mode worth alarming on, so
  wire `alarm_actions` to an SNS topic.
* **`{prefix}-route53-backup-dlq`** collects invocations that failed every retry, both
  from EventBridge and from Lambda's own asynchronous retries.
* The lambdas log at `LOG_LEVEL` (`INFO` by default) and their log groups expire after
  `log_retention_days`.
* Set `object_lock_mode` to make backups undeletable until they expire. Object Lock can
  only be enabled when the bucket is created and cannot be turned off afterwards.

## Development

The lambda code is plain Python with no dependencies beyond the `boto3` that Lambda
already provides. The tests use `unittest` and `botocore`'s `Stubber`, so no AWS account
and no extra packages are needed:

```shell
python -m unittest discover -s tests -v

terraform fmt -check -recursive
terraform init -backend=false && terraform validate
```

<!-- markdownlint-disable -->

## Requirements

| Name                                                                      | Version  |
| ------------------------------------------------------------------------- | -------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws)                   | >= 5.22  |
| <a name="requirement_archive"></a> [archive](#requirement\_archive)       | >= 2.2   |

## Providers

| Name                                                          | Version |
| ------------------------------------------------------------- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws)             | >= 5.22 |
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.2  |

## Modules

| Name                                                                       | Source                         | Version |
| -------------------------------------------------------------------------- | ------------------------------ | ------- |
| <a name="module_s3_bucket"></a> [s3\_bucket](#module\_s3\_bucket)          | cloudposse/s3-bucket/aws       | 4.9.0   |
| <a name="module_backup"></a> [backup](#module\_backup)                     | cloudposse/lambda-function/aws | 0.6.1   |
| <a name="module_backup_events"></a> [backup_events](#module_backup_events) | ./cloud_event_rules            | n/a     |
| <a name="module_restore"></a> [restore](#module\_restore)                  | cloudposse/lambda-function/aws | 0.6.1   |

## Inputs

| Name                                                                  | Description                                                                                                   | Type           | Default      | Required |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------- | ------------ | :------: |
| <a name="prefix">prefix</a>                                           | Prefix for every resource. The S3 bucket is named `{prefix}-route53-backups`, so it has to be globally unique | `string`       | n/a          |   yes    |
| <a name="alarm_actions">alarm_actions</a>                             | ARNs (usually an SNS topic) notified when a backup alarm fires                                                | `list(string)` | `[]`         |    no    |
| <a name="alarms_enabled">alarms_enabled</a>                           | Create CloudWatch alarms for backup failures and for backups that stop running                                | `bool`         | `true`       |    no    |
| <a name="backup_memory_size">backup_memory_size</a>                   | Memory (in MB) of the backup lambda                                                                           | `number`       | `512`        |    no    |
| <a name="backup_timeout">backup_timeout</a>                           | Backup lambda timeout (in seconds)                                                                            | `number`       | `300`        |    no    |
| <a name="dlq_enabled">dlq_enabled</a>                                 | Create an SQS dead letter queue for backup invocations that fail every retry                                  | `bool`         | `true`       |    no    |
| <a name="empty_bucket">empty_bucket</a>                               | Delete a non-empty S3 bucket. **THESE OBJECTS WILL NOT BE RECOVERABLE** even if versioned                     | `bool`         | `false`      |    no    |
| <a name="enable_restore">enable_restore</a>                           | Deploy the restore lambda. It is never scheduled, only invoked by hand                                        | `bool`         | `true`       |    no    |
| <a name="interval">interval</a>                                       | Interval (in minutes) of the scheduled backup. Ignored when `schedule_expression` is set                      | `number`       | `120`        |    no    |
| <a name="kms_key_arn">kms_key_arn</a>                                 | KMS key ARN for the backups. Defaults to SSE-S3 (AES256) when unset                                           | `string`       | `null`       |    no    |
| <a name="log_level">log_level</a>                                     | Log level of the lambdas                                                                                      | `string`       | `INFO`       |    no    |
| <a name="log_retention_days">log_retention_days</a>                   | Retention of the lambda log groups. Use 0 to keep the logs forever                                            | `number`       | `30`         |    no    |
| <a name="missing_backup_alarm_period">missing_backup_alarm_period</a> | Window (in seconds) the "no backup ran" alarm looks at. Defaults to twice the `interval`, capped at a day     | `number`       | `null`       |    no    |
| <a name="object_lock_days">object_lock_days</a>                       | Days a backup object stays locked. Defaults to `retention_period`                                             | `number`       | `null`       |    no    |
| <a name="object_lock_mode">object_lock_mode</a>                       | Enable S3 Object Lock, `GOVERNANCE` or `COMPLIANCE`. Only settable when the bucket is created                 | `string`       | `null`       |    no    |
| <a name="python_runtime">python_runtime</a>                           | Python runtime of the backup/restore lambdas                                                                  | `string`       | `python3.12` |    no    |
| <a name="restore_memory_size">restore_memory_size</a>                 | Memory (in MB) of the restore lambda                                                                          | `number`       | `512`        |    no    |
| <a name="restore_timeout">restore_timeout</a>                         | Restore lambda timeout (in seconds)                                                                           | `number`       | `900`        |    no    |
| <a name="retention_period">retention_period</a>                       | Time (in days) that a backup is kept before it expires                                                        | `number`       | `14`         |    no    |
| <a name="schedule_expression">schedule_expression</a>                 | EventBridge schedule expression for the backup, e.g. `cron(0 3 * * ? *)`. Overrides `interval`                | `string`       | `null`       |    no    |
| <a name="ssl_requests_only">ssl_requests_only</a>                     | Attach a bucket policy that denies any request not made over TLS                                              | `bool`         | `true`       |    no    |
| <a name="tags">tags</a>                                               | Tags applied to every resource this module creates                                                            | `map(string)`  | `{}`         |    no    |

## Outputs

| Name                                                      | Description                                                     |
| --------------------------------------------------------- | --------------------------------------------------------------- |
| <a name="alarm_names">alarm_names</a>                     | Names of the CloudWatch alarms watching the backup              |
| <a name="backup_function_arn">backup_function_arn</a>     | ARN of the backup lambda                                        |
| <a name="backup_function_name">backup_function_name</a>   | Name of the backup lambda                                       |
| <a name="dead_letter_queue_arn">dead_letter_queue_arn</a> | ARN of the backup dead letter queue                             |
| <a name="dead_letter_queue_url">dead_letter_queue_url</a> | URL of the backup dead letter queue                             |
| <a name="event_rule_arns">event_rule_arns</a>             | ARNs of the EventBridge rules invoking the backup               |
| <a name="function_names">function_names</a>               | Names of the lambdas this module created                        |
| <a name="restore_function_arn">restore_function_arn</a>   | ARN of the restore lambda, null when `enable_restore` is false  |
| <a name="restore_function_name">restore_function_name</a> | Name of the restore lambda, null when `enable_restore` is false |
| <a name="s3_bucket_arn">s3_bucket_arn</a>                 | ARN of the bucket holding the backups                           |
| <a name="s3_bucket_name">s3_bucket_name</a>               | Name of the bucket holding the backups                          |
| <a name="schedule_expression">schedule_expression</a>     | The EventBridge schedule the backup runs on                     |
<!-- markdownlint-restore -->

