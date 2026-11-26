"""Minimal server-side client for the notification engine (spec §40, §41).

Use from a trusted backend only. Never ship service or product tokens to browsers or mobile apps.
"""
import json
import random
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class NotificationError(Exception):
    def __init__(self, status, code=None, message=None, correlation_id=None):
        super().__init__(f"Notification API {status} {code or ''}".strip())
        self.status, self.code, self.message, self.correlation_id = status, code, message, correlation_id


class NotificationClient:
    """base_url is the function root, e.g. https://<ref>.supabase.co/functions/v1/notification

    organization_id is required with a product-level token and optional with a tenant service token.
    """

    def __init__(self, base_url, token, organization_id=None, timeout=20, max_retries=3):
        self.base_url, self.token = base_url.rstrip('/'), token
        self.organization_id, self.timeout, self.max_retries = organization_id, timeout, max_retries

    def _call(self, method, path, body=None, organization_id=None):
        headers = {'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'}
        org = organization_id or self.organization_id
        if org:
            headers['X-Organization-Id'] = org
        data = None if body is None else json.dumps(body).encode()
        for attempt in range(self.max_retries + 1):
            try:
                with urlopen(Request(self.base_url + path, data=data, method=method, headers=headers), timeout=self.timeout) as r:
                    raw = r.read()
                    return json.loads(raw) if raw else None
            except HTTPError as e:
                try:
                    j = json.loads(e.read() or b'{}')
                except ValueError:
                    j = {}
                retryable = e.code == 429 or e.code >= 500
                if not retryable or attempt == self.max_retries:
                    raise NotificationError(e.code, j.get('error'), j.get('message'), j.get('correlationId')) from None
                delay = float(e.headers.get('Retry-After') or 0) or min(30, 2 ** attempt)
            except URLError:
                if attempt == self.max_retries:
                    raise
                delay = min(30, 2 ** attempt)
            time.sleep(delay * (0.5 + random.random() / 2))

    def publish(self, event, organization_id=None):
        """event: {eventCode, triggerType, schemaVersion, idempotencyKey, data, recipientContext?}. Safe to retry."""
        return self._call('POST', '/v1/events/publish', event, organization_id)

    def sync_users(self, users, organization_id=None):
        """users: [{userId, displayName, email, phone, locale, active, roles?: [codes]}]"""
        return self._call('POST', '/v1/users/sync', {'users': users}, organization_id)

    def sync_roles(self, roles, organization_id=None):
        """roles: [{code, name, active?, notificationAdmin?}]"""
        return self._call('POST', '/v1/roles/sync', {'roles': roles}, organization_id)

    def exchange_token(self, user_id, scope='user', ttl_seconds=3600, organization_id=None):
        """Returns {accessToken, tokenType, scope, expiresAt} for a synced user (for the Flutter SDK)."""
        return self._call('POST', '/v1/auth/exchange', {'userId': user_id, 'scope': scope, 'ttlSeconds': ttl_seconds}, organization_id)

    def sync_metadata(self, events, organization_id=None):
        """events: [{code, version, moduleCode, triggerType, payloadSchema, metadata?}]. Changing a published version returns 409."""
        return self._call('POST', '/v1/metadata/sync', {'events': events}, organization_id)

    def provision_tenant(self, organization_id, organization_name=None, channels=None):
        """Product-level token only. Idempotent."""
        return self._call('POST', '/v1/tenants/provision', {
            'organizationId': organization_id, 'organizationName': organization_name, 'notificationChannels': channels or {}})
