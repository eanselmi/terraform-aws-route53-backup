"""Route53 Backup

Copyright (c) 2019-2022 Bridgecrew
Copyright (c) 2021-2022 Tom O'Connor <toconnorkainos>
"""
import os
import json
import time
import logging
from datetime import datetime

import boto3
import route53_utils

bucket_name = os.environ.get('S3_BUCKET_NAME', None)
aws_region = os.environ.get('REGION', "us-west-1")
s3 = boto3.client('s3')
route53 = boto3.client('route53')


def get_route53_hosted_zones(next_dns_name=None, next_hosted_zone_id=None):
    """Retrieve Route53 hosted zones"""
    if next_dns_name and next_hosted_zone_id:
        response = route53.list_hosted_zones_by_name(DNSName=next_dns_name, HostedZoneId=next_hosted_zone_id)
    else:
        response = route53.list_hosted_zones_by_name()
    zones = response['HostedZones']
    if response['IsTruncated']:
        zones += get_route53_hosted_zones(response['NextDNSName'], response['NextHostedZoneId'])

    for zone in list(filter(lambda x: x['Config']['PrivateZone'], zones)):
        zone['VPCs'] = route53.get_hosted_zone(Id=zone['Id'])['VPCs']
    return zones


def handle(event, context):
    """Handle the backup"""
    if bucket_name is None:
        logging.error("S3_BUCKET_NAME env var must be set")
        raise EnvironmentError("Please set S3_BUCKET_NAME")

    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", datetime.utcnow().utctimetuple())

    zones = get_route53_hosted_zones()
    s3.put_object(Body=json.dumps(zones).encode(),
                  Bucket=bucket_name,
                  Key=f'{timestamp}/zones.json')

    for zone in zones:
        records = route53_utils.get_route53_zone_records(zone['Id'])
        s3.put_object(Body=json.dumps(records).encode(),
                      Bucket=bucket_name,
                      # AWS returns the name with the trailing dot (.)
                      Key=f"{timestamp}/{zone['Name']}json")

    health_checks = route53_utils.get_route53_health_checks()
    for health_check in health_checks:
        tags = route53.list_tags_for_resource(ResourceType='healthcheck', ResourceId=health_check['Id'])
        health_check['Tags'] = tags['ResourceTagSet']['Tags']

    s3.put_object(Body=json.dumps(health_checks).encode(),
                  Bucket=bucket_name,
                  Key=f"{timestamp}/health-checks.json")

    s3.put_object(Body=timestamp.encode(),
                  Bucket=bucket_name,
                  Key="latest_backup_timestamp")

    return f"Success: {timestamp}: Zones: {len(zones)} HealthChecks: {len(health_checks)}"
