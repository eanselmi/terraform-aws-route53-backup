"""Helpers shared by the Route53 backup and restore lambdas."""

import itertools
import logging
import os

import boto3
from botocore.config import Config

# Route53 throttles the whole account at around five requests per second, so a
# sweep over a few hundred zones will be throttled no matter how it is written.
# Adaptive mode backs off on the client side instead of failing the backup.
BOTO_CONFIG = Config(retries={'max_attempts': 10, 'mode': 'adaptive'})

# Limits of a single ChangeResourceRecordSets request. An UPSERT counts twice
# against both budgets, and an alias record set counts as one element even
# though it carries no ResourceRecords.
# https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/DNSLimitations.html
MAX_CHANGES_PER_BATCH = 1000
MAX_RECORD_ELEMENTS_PER_BATCH = 1000
MAX_VALUE_CHARACTERS_PER_BATCH = 32000

# ListTagsForResources accepts at most ten resources per call.
MAX_TAG_RESOURCES_PER_CALL = 10

_CLIENTS = {}


def configure_logging():
    """Set the root log level from the LOG_LEVEL env var. Safe to call twice."""
    level = os.environ.get('LOG_LEVEL', 'INFO').upper()
    logging.getLogger().setLevel(getattr(logging, level, logging.INFO))


def client(service_name):
    """Return a cached boto3 client so warm invocations reuse the connection."""
    if service_name not in _CLIENTS:
        _CLIENTS[service_name] = boto3.client(service_name, config=BOTO_CONFIG)
    return _CLIENTS[service_name]


def reset_clients():
    """Drop the client cache. Only used by the tests."""
    _CLIENTS.clear()


def iter_hosted_zones():
    paginator = client('route53').get_paginator('list_hosted_zones')
    for page in paginator.paginate():
        yield from page['HostedZones']


def iter_zone_records(zone_id):
    paginator = client('route53').get_paginator('list_resource_record_sets')
    for page in paginator.paginate(HostedZoneId=bare_zone_id(zone_id)):
        yield from page['ResourceRecordSets']


def iter_health_checks():
    paginator = client('route53').get_paginator('list_health_checks')
    for page in paginator.paginate():
        yield from page['HealthChecks']


def get_route53_zone_records(zone_id):
    return list(iter_zone_records(zone_id))


def get_route53_health_checks():
    return list(iter_health_checks())


def find_hosted_zones_by_name(name):
    """Return every hosted zone whose name matches, public and private alike."""
    route53 = client('route53')
    wanted = normalize_zone_name(name)
    matches = []

    kwargs = {'DNSName': wanted}
    while True:
        response = route53.list_hosted_zones_by_name(**kwargs)
        for zone in response['HostedZones']:
            if normalize_zone_name(zone['Name']) == wanted:
                matches.append(zone)
            else:
                # The listing is ordered by name, so the first mismatch after
                # our name means there is nothing left to find.
                return matches
        if not response.get('IsTruncated'):
            return matches
        kwargs = {'DNSName': response['NextDNSName'],
                  'HostedZoneId': response['NextHostedZoneId']}


def list_tags(resource_type, resource_ids):
    """Return {resource_id: tags} for up to any number of Route53 resources."""
    route53 = client('route53')
    tags = {}
    for chunk in chunked(resource_ids, MAX_TAG_RESOURCES_PER_CALL):
        response = route53.list_tags_for_resources(
            ResourceType=resource_type, ResourceIds=list(chunk))
        for tag_set in response['ResourceTagSets']:
            tags[tag_set['ResourceId']] = tag_set.get('Tags', [])
    return tags


def chunked(iterable, size):
    """Yield lists of at most `size` items."""
    iterator = iter(iterable)
    while True:
        chunk = list(itertools.islice(iterator, size))
        if not chunk:
            return
        yield chunk


def change_weight(change):
    """Return (record elements, value characters) a change costs in a batch."""
    record_set = change.get('ResourceRecordSet', {})
    records = record_set.get('ResourceRecords') or []
    # An alias record set has no ResourceRecords but still counts as one.
    elements = max(len(records), 1)
    characters = sum(len(record.get('Value', '')) for record in records)

    if change.get('Action') == 'UPSERT':
        elements *= 2
        characters *= 2

    return elements, characters


def batch_changes(changes,
                  max_changes=MAX_CHANGES_PER_BATCH,
                  max_elements=MAX_RECORD_ELEMENTS_PER_BATCH,
                  max_characters=MAX_VALUE_CHARACTERS_PER_BATCH):
    """Split changes into batches that fit inside the Route53 request limits."""
    batch, elements, characters = [], 0, 0

    for change in changes:
        weight, length = change_weight(change)
        too_big = (len(batch) + 1 > max_changes
                   or elements + weight > max_elements
                   or characters + length > max_characters)
        if batch and too_big:
            yield batch
            batch, elements, characters = [], 0, 0

        batch.append(change)
        elements += weight
        characters += length

    if batch:
        yield batch


def bare_zone_id(zone_id):
    return zone_id.rsplit('/', 1)[-1]


def normalize_zone_name(name):
    name = name.lower()
    return name if name.endswith('.') else f'{name}.'


def zone_records_key(timestamp, zone_id):
    return f'{timestamp}/zones/{bare_zone_id(zone_id)}.json'


def legacy_zone_records_key(timestamp, zone_name):
    return f'{timestamp}/{zone_name}json'


def manifest_key(timestamp):
    return f'{timestamp}/manifest.json'


def zones_key(timestamp):
    return f'{timestamp}/zones.json'


def health_checks_key(timestamp):
    return f'{timestamp}/health-checks.json'


LATEST_BACKUP_KEY = 'latest_backup_timestamp'
