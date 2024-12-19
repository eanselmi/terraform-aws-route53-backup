"""Route53 Backup

Copyright (c) 2019-2022 Bridgecrew Inc.
Copyright (c) 2021-2022 Tom O'Connor <toconnorkainos>
Copyright (c) 2022      Outside Open, LLC
"""
import os
import json
import time
from datetime import datetime

import boto3
from botocore.exceptions import ClientError
import route53_utils

bucket_name = os.environ.get("S3_BUCKET_NAME", None)

s3 = boto3.client('s3')
route53 = boto3.client('route53')


def restore_hosted_zone(zone):
    """Restores the hosted zone"""
    if zone['Config']['PrivateZone']:
        restored_zone = route53.create_hosted_zone(
            Name=zone['Name'],
            CallerReference=get_unique_caller_id(zone['Id']),
            HostedZoneConfig=zone['Config'],
            VPC=zone['VPCs'][0]
        )['HostedZone']
    else:
        restored_zone = route53.create_hosted_zone(
            Name=zone['Name'],
            CallerReference=get_unique_caller_id(zone['Id']),
            HostedZoneConfig=zone['Config']
        )['HostedZone']

    print(f'Restored the zone {zone["Id"]}')
    return restored_zone


def get_unique_caller_id(resource_id):
    """
    Creates a unique caller ID, which is required to avoid processing a single request multiple times by mistake
    :param resource_id: The ID of the resource to be restored
    :return: A unique string
    """
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", datetime.utcnow().utctimetuple())
    return f'{timestamp}-{resource_id}'


def create_zone_if_not_exist(zone):
    """Creates the zone if it doesn't exist"""
    try:
        return route53.get_hosted_zone(Id=zone['Id'])['HostedZone']
    except ClientError as err:
        if err.response['Error'].get('Code', False) and err.response['Error']['Code'] == 'NoSuchHostedZone':
            return restore_hosted_zone(zone)

        print(err)

    return None


def get_s3_object_as_string(key):
    """Retrieves the S3 object as a string"""
    return s3.get_object(Bucket=bucket_name, Key=key)['Body'].read()


def restore_zones(timestamp, zones, dryrun):
    """Restores the zones"""
    restored = 0
    for zone in zones:
        if (zone := create_zone_if_not_exist(zone)) is None:
            continue

        # AWS returns the name with the trailing dot (.)
        backups = json.loads(get_s3_object_as_string(f'{timestamp}/{zone["Name"]}json'))
        current = route53_utils.get_route53_zone_records(zone['Id'])

        updates = list(filter(lambda x: x not in current, backups))
        changes = list(map(lambda x: {"Action": "UPSERT", "ResourceRecordSet": x}, updates))

        if len(changes) > 0:
            if not dryrun:
                route53.change_resource_record_sets(
                    HostedZoneId=zone['Id'],
                    ChangeBatch={'Comment': 'Restored by route53 restore lambda', 'Changes': changes}
                )
                print(f"Restored zone {zone['Name']} from {timestamp}")
            restored += 1

    return restored


def restore_health_checks(timestamp, dryrun):
    """Restores the health checks"""
    backups = json.loads(get_s3_object_as_string(f'{timestamp}/health-checks.json'))
    current = route53_utils.get_route53_health_checks()

    # Compare the health checks by their IDs, actual objects are a little different
    inserts = list(filter(lambda x: x['Id'] not in list(map(lambda y: y['Id'], current)), backups))
    restored = 0
    for health_check in inserts:
        request_id = get_unique_caller_id(health_check['Id'])
        if not dryrun:
            created = route53.create_health_check(
                CallerReference=request_id,
                HealthCheckConfig=health_check['HealthCheckConfig']
            )['HealthCheck']

            if len(health_check.get('Tags', [])) > 0:
                route53.change_tags_for_resource(ResourceType='healthcheck',
                                                 ResourceId=created['Id'],
                                                 AddTags=health_check['Tags'])

            print(f"Restored health check {health_check['Id']} from {timestamp}")
        restored += 1

    return restored


def handle(event, context):
    """Handles the restore"""
    if event.get('from', False):
        timestamp = event['from']
    else:
        timestamp = get_s3_object_as_string('latest_backup_timestamp').decode()

    zones = json.loads(get_s3_object_as_string(f'{timestamp}/zones.json'))

    if zone_ids := event.get('ids', None):
        zones = list(filter(lambda zone: zone['Id'] not in zone_ids, zones))

    if zone_names := event.get('ids', None):
        zones = list(filter(lambda zone: zone['Name'] not in zone_names, zones))

    print(f'Using backup taken at {timestamp}')

    dryrun = event.get('dryrun', False)

    zone_count = restore_zones(timestamp, zones, dryrun)
    check_count = restore_health_checks(timestamp, dryrun)

    status = 'No zones or health checks needed to be restored'
    if (zone_count + check_count) > 0:
        stats = []
        if zone_count > 0:
            stats.append(f'Zones: {zone_count}')
        if check_count > 0:
            stats.append(f'Health checks: {check_count}')
        status = f'Restored from {timestamp} {" ".join(stats)}'

    return status
