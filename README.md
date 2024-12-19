<!-- markdownlint-disable -->
# terraform-aws-route53-backup [![Latest Release](https://img.shields.io/github/release/eanselmi/terraform-aws-route53-backup.svg)](https://github.com/eanselmi/terraform-aws-route53-backup/releases/latest)
<!-- markdownlint -->

Terraform module for provisioning Route53 backup/restore lambda functions.


Included Features:
* S3 bucket is created to maintain versions and retention
* Backup of Route53 DNS Records
* Backup of Route53 Health checks
* Restore capability to both of the above

## Usage

### Simple example:

```hcl
module "instance" {
    source = "eanselmi/route53-backup/aws"
    # Outside Open recommends pinning every module to a specific version
    # version     = "x.x.x"
    prefix = "dev"
}
```

### Override the defaults

```hcl
module "instance" {
    source = "eanselmi/route53-backup/aws"
    # Outside Open recommends pinning every module to a specific version
    # version        = "x.x.x"
    prefix           = "dev"
    retention_period = 5
    interval         = 86400
    enable_restore   = false
}
```

### Destroying the S3 bucket

You will need to set `empty_bucket = true`, run `terraform apply`, then you can run `terraform destroy`.

### Manually triggering the functions

You can use AWS CLI to trigger either lambda
  
```shell
# backup
aws lambda invoke --function-name {prefix}-route53-backup --output text /dev/stdout

# restore (all zones)
aws lambda invoke --function-name {prefix}-route53-restore --output text /dev/stdout

# restore (single zone by name)
aws lambda invoke --function-name {prefix}-route53-restore --payload '{"names":["example.com"]}' --output text /dev/stdout

# restore (single zone by id)
aws lambda invoke --function-name {prefix}-route53-restore --payload '{"ids":["Z750C051B"]}' --output text /dev/stdout

# restore (specific backup)
aws lambda invoke --function-name {prefix}-route53-restore --payload '{"from":"2022-12-28T00:00:00Z"}' --output text /dev/stdout
```

<!-- markdownlint-disable -->

## Requirements

| Name                                                                      | Version   |
| ------------------------------------------------------------------------- | --------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 0.13.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws)                   | >= 3.68.0 |

## Providers

| Name                                              | Version   |
| ------------------------------------------------- | --------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 3.68.0 |

## Modules

| Name                                                                       | Source                         | Version |
| -------------------------------------------------------------------------- | ------------------------------ | ------- |
| <a name="module_s3_bucket"></a> [s3\_bucket](#module\_s3\_bucket)          | cloudposse/s3-bucket/aws       | 1.0.0   |
| <a name="module_backup"></a> [backup](#module\_backup)                     | cloudposse/lambda-function/aws | 0.4.1   |
| <a name="module_backup_events"></a> [backup_events](#module_backup_events) | _cloud_event_rules             |         |
| <a name="module_restore"></a> [restore](#module\_restore)                  | cloudposse/lambda-function/aws | 0.4.1   |

## Inputs

| Name                                            | Description                                                                                                     | Type          | Default | Required |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ------------- | ------- | :------: |
| <a name="backup_timeout">backup_timeout</a>     | Lambda Timeout (in seconds)                                                                                     | `number`      | 300     |    no    |
| <a name="enable_restore">enable_restore</a>     | Install the restore lambda?                                                                                     | `bool`        | true    |    no    |
| <a name="empty_bucket">empty_bucket</a>         | Delete a non-empty S3 bucket. **THESE OBJECTS WILL NOT BE RECOVERABLE** even if versioned and stored in Glacier | `bool`        | false   |    no    |
| <a name="interval">interval</a>                 | Interval (in minutes) of scheduled backup                                                                       | `number`      | 120     |    no    |
| <a name="prefix">prefix</a>                     | Prefix for naming                                                                                               | `string`      | ``      |    no    |
| <a name="retention_period">retention_period</a> | Time (in days) to keep the backups                                                                              | `number`      | 14      |    no    |
| <a name="s3_prefix">s3_prefix</a>               | Prefix for the S3 bucket                                                                                        | `string`      | ``      |   yes    |
| <a name="tags">tags</a>                         | Tags                                                                                                            | `map(string)` | {}      |    no    |


## Outputs

| Name                                        | Description                            |
| ------------------------------------------- | -------------------------------------- |
| <a name="stack_name">stack_name</a>         | Name of the stack                      |
| <a name="function_names">function_names</a> | Name of the functions that were set up |
<!-- markdownlint-restore -->

