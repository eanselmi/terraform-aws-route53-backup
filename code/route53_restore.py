"""Restore hosted zones, record sets and health checks from an S3 backup.

The restore is additive: records are created or updated, never deleted, so a
record added after the backup was taken survives. Health checks are reconciled
before the zones, because a restored health check gets a new id and the record
sets that point at it have to be rewritten to the new one.
"""

import json
import logging
import os
from datetime import datetime, timezone

from botocore.exceptions import ClientError

import route53_utils
from route53_utils import client

# Route53 manages these at the apex of a zone. A recreated zone gets a fresh
# delegation set, so restoring the old values would break the delegation.
APEX_MANAGED_TYPES = ('NS', 'SOA')

# ListResourceRecordSets returns this, ChangeResourceRecordSets must not.
UNRESTORABLE_RECORD_FIELDS = ('TrafficPolicyInstanceId',)

HOSTED_ZONE_CONFIG_FIELDS = ('Comment', 'PrivateZone')

logger = logging.getLogger(__name__)


def bucket_name():
    name = os.environ.get('S3_BUCKET_NAME')
    if not name:
        raise EnvironmentError('S3_BUCKET_NAME must be set')
    return name


def get_s3_object_as_string(key):
    return client('s3').get_object(Bucket=bucket_name(), Key=key)['Body'].read()


def get_s3_object_as_json(key):
    return json.loads(get_s3_object_as_string(key))


# --------------------------------------------------------------------------
# Pure helpers
# --------------------------------------------------------------------------

def is_apex_managed_record(record, zone_name):
    return (record['Type'] in APEX_MANAGED_TYPES
            and route53_utils.normalize_zone_name(record['Name'])
            == route53_utils.normalize_zone_name(zone_name))


def strip_unrestorable_fields(record):
    stripped = dict(record)
    for field in UNRESTORABLE_RECORD_FIELDS:
        stripped.pop(field, None)
    return stripped


def prepare_record(record, health_check_ids):
    """Shape a backed up record set into something the API accepts.

    Returns None when the record points at a health check that no longer
    exists and could not be recreated, since sending it would fail the whole
    batch it travels in.
    """
    prepared = strip_unrestorable_fields(record)

    health_check_id = prepared.get('HealthCheckId')
    if health_check_id is not None:
        resolved = health_check_ids.get(health_check_id)
        if resolved is None:
            return None
        prepared['HealthCheckId'] = resolved

    return prepared


def records_to_restore(backup_records, live_records, zone_name, health_check_ids):
    """Return (changes, skipped) for the records that differ from what is live.

    The comparison is made against the record as it would be sent, not as it
    was backed up, so a record whose health check id had to be remapped is not
    rewritten on every single run.
    """
    live = [strip_unrestorable_fields(record) for record in live_records]
    changes, skipped = [], []

    for record in backup_records:
        if is_apex_managed_record(record, zone_name):
            continue

        prepared = prepare_record(record, health_check_ids)
        if prepared is None:
            skipped.append(record)
            continue
        if prepared in live:
            continue

        changes.append({'Action': 'UPSERT', 'ResourceRecordSet': prepared})

    return changes, skipped


def select_zones(zones, event):
    ids = {route53_utils.bare_zone_id(zone_id)
           for zone_id in event.get('ids') or []}
    names = {route53_utils.normalize_zone_name(name)
             for name in event.get('names') or []}

    if not ids and not names:
        return zones

    selected = [zone for zone in zones
                if route53_utils.bare_zone_id(zone['Id']) in ids
                or route53_utils.normalize_zone_name(zone['Name']) in names]

    unmatched = (ids - {route53_utils.bare_zone_id(zone['Id']) for zone in selected}
                 | names - {route53_utils.normalize_zone_name(zone['Name'])
                            for zone in selected})
    for missing in sorted(unmatched):
        logger.warning('No zone matching %s in this backup', missing)

    return selected


def health_check_fingerprint(health_check):
    return json.dumps(health_check['HealthCheckConfig'], sort_keys=True)


def unique_caller_reference(resource_id):
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return f'{timestamp}-{resource_id}'


# --------------------------------------------------------------------------
# Hosted zones
# --------------------------------------------------------------------------

def find_live_zone(zone):
    """Locate the live counterpart of a backed up zone, by id then by name.

    Looking the zone up by name as well means a zone that was deleted and
    recreated by hand is reconciled instead of being duplicated.
    """
    route53 = client('route53')
    try:
        return route53.get_hosted_zone(
            Id=route53_utils.bare_zone_id(zone['Id']))['HostedZone']
    except ClientError as err:
        if err.response['Error'].get('Code') != 'NoSuchHostedZone':
            logger.warning('Could not read zone %s: %s', zone['Id'], err)
            return None

    private = bool(zone.get('Config', {}).get('PrivateZone'))
    matches = [candidate
               for candidate in route53_utils.find_hosted_zones_by_name(zone['Name'])
               if bool(candidate.get('Config', {}).get('PrivateZone')) == private]

    if not matches:
        return None
    if len(matches) > 1:
        logger.warning('%d zones named %s share the same visibility, using %s',
                       len(matches), zone['Name'], matches[0]['Id'])

    logger.info('Zone %s was recreated as %s, reconciling against it',
                zone['Id'], matches[0]['Id'])
    return matches[0]


def create_hosted_zone(zone):
    """Recreate a hosted zone that no longer exists. Returns None if it cannot."""
    route53 = client('route53')
    config = {field: zone['Config'][field]
              for field in HOSTED_ZONE_CONFIG_FIELDS if field in zone.get('Config', {})}
    params = {
        'Name': zone['Name'],
        'CallerReference': unique_caller_reference(zone['Id']),
        'HostedZoneConfig': config,
    }

    vpcs = zone.get('VPCs', [])
    if config.get('PrivateZone'):
        if not vpcs:
            logger.warning('Skipping private zone %s, the backup holds no VPC association',
                           zone['Name'])
            return None
        params['VPC'] = vpc_reference(vpcs[0])

    created = route53.create_hosted_zone(**params)['HostedZone']

    for vpc in vpcs[1:]:
        try:
            route53.associate_vpc_with_hosted_zone(
                HostedZoneId=created['Id'], VPC=vpc_reference(vpc))
        except ClientError as err:
            logger.warning('Could not associate %s with %s: %s',
                           vpc['VPCId'], zone['Name'], err)

    logger.info('Restored zone %s as %s', zone['Id'], created['Id'])
    return created


def vpc_reference(vpc):
    return {'VPCRegion': vpc['VPCRegion'], 'VPCId': vpc['VPCId']}


def restore_zone_tags(zone, live_zone):
    tags = zone.get('Tags') or []
    if not tags:
        return
    try:
        client('route53').change_tags_for_resource(
            ResourceType='hostedzone',
            ResourceId=route53_utils.bare_zone_id(live_zone['Id']),
            AddTags=tags)
    except ClientError as err:
        logger.warning('Could not restore tags of zone %s: %s', zone['Name'], err)


def get_zone_records_backup(timestamp, zone):
    try:
        return get_s3_object_as_json(
            route53_utils.zone_records_key(timestamp, zone['Id']))
    except ClientError as err:
        if err.response['Error'].get('Code') not in ('NoSuchKey', '404'):
            raise

    # Backups written by earlier versions keyed the records by zone name.
    return get_s3_object_as_json(
        route53_utils.legacy_zone_records_key(timestamp, zone['Name']))


# --------------------------------------------------------------------------
# Health checks
# --------------------------------------------------------------------------

def reconcile_health_checks(timestamp, dryrun):
    """Recreate the missing health checks.

    Returns (id map, created count). The map translates the health check ids
    stored in the backup into the ids that are live now, so record sets can be
    rewritten to point at the right check.
    """
    backups = get_s3_object_as_json(route53_utils.health_checks_key(timestamp))
    route53 = client('route53')

    live = route53_utils.get_route53_health_checks()
    by_fingerprint = {health_check_fingerprint(health_check): health_check['Id']
                      for health_check in live}
    # A record may point at a health check that is live but absent from the
    # backup, so those ids map to themselves.
    id_map = {health_check['Id']: health_check['Id'] for health_check in live}

    created = 0
    for health_check in backups:
        fingerprint = health_check_fingerprint(health_check)
        existing = by_fingerprint.get(fingerprint)
        if existing:
            id_map[health_check['Id']] = existing
            continue

        created += 1
        if dryrun:
            logger.info('Would restore health check %s from %s',
                        health_check['Id'], timestamp)
            id_map[health_check['Id']] = health_check['Id']
            continue

        new = route53.create_health_check(
            CallerReference=unique_caller_reference(health_check['Id']),
            HealthCheckConfig=health_check['HealthCheckConfig'])['HealthCheck']

        by_fingerprint[fingerprint] = new['Id']
        id_map[health_check['Id']] = new['Id']

        if health_check.get('Tags'):
            route53.change_tags_for_resource(ResourceType='healthcheck',
                                             ResourceId=new['Id'],
                                             AddTags=health_check['Tags'])

        logger.info('Restored health check %s as %s from %s',
                    health_check['Id'], new['Id'], timestamp)

    return id_map, created


# --------------------------------------------------------------------------
# Zones
# --------------------------------------------------------------------------

def restore_zone(timestamp, backup_zone, health_check_ids, dryrun):
    """Reconcile one zone. Returns a stats dict for the run summary."""
    stats = {'created': False, 'records': 0, 'skipped': 0}

    live_zone = find_live_zone(backup_zone)
    if live_zone is None:
        stats['created'] = True
        if not dryrun:
            live_zone = create_hosted_zone(backup_zone)
            if live_zone is None:
                stats['created'] = False
                return stats
            restore_zone_tags(backup_zone, live_zone)
        else:
            logger.info('Would restore zone %s from %s', backup_zone['Name'], timestamp)

    zone_name = live_zone['Name'] if live_zone else backup_zone['Name']
    live_records = (route53_utils.get_route53_zone_records(live_zone['Id'])
                    if live_zone else [])

    backup_records = get_zone_records_backup(timestamp, backup_zone)
    changes, skipped = records_to_restore(
        backup_records, live_records, zone_name, health_check_ids)

    for record in skipped:
        logger.warning('Skipping %s %s in zone %s, its health check %s is gone',
                       record['Type'], record['Name'], zone_name,
                       record.get('HealthCheckId'))

    stats['records'] = len(changes)
    stats['skipped'] = len(skipped)
    if not changes:
        return stats

    batches = list(route53_utils.batch_changes(changes))
    if dryrun:
        logger.info('Would restore %d records in zone %s from %s (%d batches)',
                    len(changes), zone_name, timestamp, len(batches))
        return stats

    route53 = client('route53')
    for batch in batches:
        route53.change_resource_record_sets(
            HostedZoneId=route53_utils.bare_zone_id(live_zone['Id']),
            ChangeBatch={'Comment': f'Restored from backup {timestamp}',
                         'Changes': batch})

    logger.info('Restored %d records in zone %s from %s (%d batches)',
                len(changes), zone_name, timestamp, len(batches))
    return stats


def restore_zones(timestamp, zones, health_check_ids, dryrun):
    summary = {'zones_changed': 0, 'zones_created': 0,
               'records': 0, 'records_skipped': 0}

    for backup_zone in zones:
        stats = restore_zone(timestamp, backup_zone, health_check_ids, dryrun)
        if stats['created']:
            summary['zones_created'] += 1
        if stats['created'] or stats['records']:
            summary['zones_changed'] += 1
        summary['records'] += stats['records']
        summary['records_skipped'] += stats['skipped']

    return summary


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def handle(event, context):
    route53_utils.configure_logging()

    if not isinstance(event, dict):
        raise ValueError(
            f'The restore expects a JSON object as its event, got {type(event).__name__}')

    dryrun = bool(event.get('dryrun', False))
    timestamp = event.get('from') or get_s3_object_as_string(
        route53_utils.LATEST_BACKUP_KEY).decode()

    logger.info('Restoring from the backup taken at %s%s',
                timestamp, ' (dry run)' if dryrun else '')

    zones = select_zones(
        get_s3_object_as_json(route53_utils.zones_key(timestamp)), event)

    health_check_ids, health_checks_restored = reconcile_health_checks(timestamp, dryrun)
    summary = restore_zones(timestamp, zones, health_check_ids, dryrun)

    summary.update({'timestamp': timestamp,
                    'dryrun': dryrun,
                    'health_checks': health_checks_restored})

    logger.info('Restore of %s finished: %s', timestamp, summary)
    return summary
