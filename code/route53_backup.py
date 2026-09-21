"""Write every hosted zone, record set and health check of the account to S3.

The backup is laid out as one timestamped prefix per run:

    <timestamp>/zones.json                  every hosted zone, with VPCs and tags
    <timestamp>/zones/<zone id>.json        the record sets of one zone
    <timestamp>/health-checks.json          every health check, with its tags
    <timestamp>/manifest.json               what the run wrote, for verification
    latest_backup_timestamp                 the prefix the restore defaults to

`latest_backup_timestamp` is written last and only on success, so a run that
fails part way through never becomes the backup the restore picks up.
"""

import json
import logging
import os
from datetime import datetime, timezone

from botocore.exceptions import ClientError

import route53_utils
from route53_utils import client

MANIFEST_VERSION = 1

logger = logging.getLogger(__name__)


def backup_timestamp():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def collect_hosted_zones():
    """Every hosted zone, enriched with the VPCs and tags a restore needs."""
    zones = list(route53_utils.iter_hosted_zones())
    route53 = client('route53')

    for zone in zones:
        if zone.get('Config', {}).get('PrivateZone'):
            zone['VPCs'] = route53.get_hosted_zone(Id=zone['Id']).get('VPCs', [])

    tags = route53_utils.list_tags(
        'hostedzone', [route53_utils.bare_zone_id(zone['Id']) for zone in zones])
    for zone in zones:
        zone['Tags'] = tags.get(route53_utils.bare_zone_id(zone['Id']), [])

    return zones


def collect_health_checks():
    health_checks = route53_utils.get_route53_health_checks()

    tags = route53_utils.list_tags(
        'healthcheck', [health_check['Id'] for health_check in health_checks])
    for health_check in health_checks:
        health_check['Tags'] = tags.get(health_check['Id'], [])

    return health_checks


def put_json(bucket_name, key, body):
    client('s3').put_object(Body=json.dumps(body).encode(),
                            Bucket=bucket_name,
                            Key=key,
                            ContentType='application/json')


def backup_zone_records(bucket_name, timestamp, zone):
    """Write one zone's records. Returns the record count, or None if it went away."""
    try:
        records = route53_utils.get_route53_zone_records(zone['Id'])
    except ClientError as err:
        if err.response['Error'].get('Code') == 'NoSuchHostedZone':
            # Deleted between listing the zones and reading them. Not a failure,
            # the zone simply does not belong in this backup.
            logger.warning('Zone %s (%s) disappeared during the backup, skipping it',
                           zone['Name'], zone['Id'])
            return None
        raise

    put_json(bucket_name, route53_utils.zone_records_key(timestamp, zone['Id']), records)
    logger.info('Backed up %d records of zone %s (%s)',
                len(records), zone['Name'], zone['Id'])
    return len(records)


def handle(event, context):
    route53_utils.configure_logging()

    bucket_name = os.environ.get('S3_BUCKET_NAME')
    if not bucket_name:
        raise EnvironmentError('S3_BUCKET_NAME must be set')

    timestamp = backup_timestamp()
    logger.info('Starting Route53 backup %s into %s', timestamp, bucket_name)

    zones = collect_hosted_zones()

    backed_up, record_total = [], 0
    for zone in zones:
        count = backup_zone_records(bucket_name, timestamp, zone)
        if count is None:
            continue
        backed_up.append((zone, count))
        record_total += count

    # Written after the per zone files so it only lists zones that really made
    # it into this backup.
    put_json(bucket_name, route53_utils.zones_key(timestamp),
             [zone for zone, _ in backed_up])

    health_checks = collect_health_checks()
    put_json(bucket_name, route53_utils.health_checks_key(timestamp), health_checks)

    summary = {
        'manifest_version': MANIFEST_VERSION,
        'timestamp': timestamp,
        'zones': len(backed_up),
        'records': record_total,
        'health_checks': len(health_checks),
        'zone_details': [
            {
                'id': route53_utils.bare_zone_id(zone['Id']),
                'name': zone['Name'],
                'private': bool(zone.get('Config', {}).get('PrivateZone')),
                'records': count,
            }
            for zone, count in backed_up
        ],
    }
    put_json(bucket_name, route53_utils.manifest_key(timestamp), summary)

    client('s3').put_object(Body=timestamp.encode(),
                            Bucket=bucket_name,
                            Key=route53_utils.LATEST_BACKUP_KEY,
                            ContentType='text/plain')

    logger.info('Backup %s complete: %d zones, %d records, %d health checks',
                timestamp, len(backed_up), record_total, len(health_checks))

    return {key: summary[key] for key in
            ('timestamp', 'zones', 'records', 'health_checks')}
