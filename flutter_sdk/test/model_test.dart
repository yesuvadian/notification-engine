import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notification_sdk/notification_sdk.dart';

NotificationApi api(MockClient c, {String? product}) => NotificationApi(
    baseUrl: Uri.parse('https://x.supabase.co/functions/v1/notification/'),
    organizationId: 'org-1',
    accessToken: () async => 'tok',
    productCode: product,
    client: c);

void main() {
  test('parses unread item', () {
    final item = NotificationItem.fromJson({'id': '1', 'title': 'Approval', 'body': 'Review'});
    expect(item.read, false);
    expect(item.design, isEmpty);
    expect(item.createdAt, isNull);
  });

  test('sends auth, organization and optional product headers', () async {
    late http.BaseRequest seen;
    final c = MockClient((r) async {
      seen = r;
      return http.Response(jsonEncode({'count': 3}), 200);
    });
    expect(await api(c).unreadCount(), 3);
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(seen.headers['X-Organization-Id'], 'org-1');
    expect(seen.headers.containsKey('X-Product-Code'), isFalse);
    await api(c, product: 'cmm').unreadCount();
    expect(seen.headers['X-Product-Code'], 'cmm');
    expect(seen.url.path, '/functions/v1/notification/v1/notifications/unread-count');
  });

  test('inbox pages with cursor and keeps the 0.1 list API', () async {
    final c = MockClient((r) async {
      final first = r.url.queryParameters['before'] == null;
      return http.Response(
          jsonEncode({
            'items': [
              {'id': first ? 'a' : 'b', 'title': 't', 'body': 'b', 'created_at': '2026-11-26T10:00:00Z'}
            ],
            'nextCursor': first ? 'cur' : null
          }),
          200);
    });
    final p1 = await api(c).inboxPage(limit: 1);
    expect(p1.items.single.id, 'a');
    expect(p1.nextCursor, 'cur');
    final p2 = await api(c).inboxPage(limit: 1, cursor: p1.nextCursor);
    expect(p2.items.single.id, 'b');
    expect(p2.nextCursor, isNull);
    expect((await api(c).inbox()).single.createdAt, DateTime.utc(2026, 11, 26, 10));
  });

  test('errors expose server code and keep status', () async {
    final c = MockClient((r) async => http.Response(
        jsonEncode({'error': 'organization_required', 'message': 'm', 'correlationId': 'c1'}), 400));
    try {
      await api(c).inbox();
      fail('expected exception');
    } on NotificationApiException catch (e) {
      expect(e.status, 400);
      expect(e.code, 'organization_required');
      expect(e.correlationId, 'c1');
    }
    final legacy = NotificationApiException(401);
    expect(legacy.toString(), 'Notification request failed (401)');
  });

  test('mark all read, devices and preferences', () async {
    final bodies = <String, dynamic>{};
    final c = MockClient((r) async {
      bodies[r.url.path.split('/v1/').last] = r.body.isEmpty ? null : jsonDecode(r.body);
      if (r.url.path.endsWith('/preferences')) {
        return http.Response(jsonEncode({'items': [{'channel': 'SMS', 'enabled': false, 'consent': true}]}), 200);
      }
      return http.Response(jsonEncode({'ok': true, 'updated': 2}), 200);
    });
    final a = api(c);
    expect(await a.markAllRead(), 2);
    expect(bodies['notifications/mark-read'], {'all': true});
    await a.registerDevice(token: 'fcm', installationId: 'i1', platform: 'android');
    expect(bodies['devices/register'], {'token': 'fcm', 'installationId': 'i1', 'platform': 'android'});
    final prefs = await a.setPreferences([ChannelPreference(channel: 'SMS', enabled: false, consent: true)]);
    expect(prefs.single.enabled, isFalse);
  });

  test('rejects plain http to non-local hosts', () {
    expect(
        () => NotificationApi(baseUrl: Uri.parse('http://example.com/'), organizationId: 'o', accessToken: () async => 't'),
        throwsArgumentError);
  });
}
