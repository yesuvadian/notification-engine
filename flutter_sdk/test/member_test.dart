// Unit and widget tests for the member app (C1 preferences, C2 inbox page, C3 push helper), every option.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notification_sdk/notification_sdk.dart';

class Fake {
  final calls = <http.Request>[];
  final Map<String, dynamic Function(http.Request)> routes;
  Fake(this.routes);
  MockClient get client => MockClient((r) async {
        calls.add(r);
        for (final e in routes.entries) {
          if (_match(r, e.key)) {
            final v = e.value(r);
            if (v is http.Response) return v;
            return http.Response(jsonEncode(v), 200);
          }
        }
        return http.Response(jsonEncode({'error': 'not_found'}), 404);
      });
  static bool _match(http.Request r, String key) {
    final i = key.indexOf(' ');
    return r.method == key.substring(0, i) && r.url.path.endsWith(key.substring(i + 1));
  }

  List<Map<String, dynamic>> bodies(String suffix) => calls
      .where((c) => _match(c, suffix))
      .map((c) => Map<String, dynamic>.from(jsonDecode(c.body)))
      .toList();
}

NotificationApi apiFor(Fake f) => NotificationApi(
    baseUrl: Uri.parse('https://x.test/functions/v1/notification/'),
    organizationId: 'org-1',
    accessToken: () async => 'tok',
    client: f.client);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

Map<String, dynamic> settingsJson({bool managed = true, bool locked = true, String prompt = 'after_first_notification', bool push = true, bool groupByDay = true}) => {
      'managed': managed,
      'preferencesLocked': locked,
      'inbox': {'retentionDays': 90, 'unreadBadge': true, 'groupByDay': groupByDay},
      'push': {'enabled': push, 'prompt': prompt, 'explanation': 'Get visitor alerts'}
    };

class FakePush extends PushPlatform {
  bool permitted, grant;
  int asked = 0, opened = 0;
  FakePush({this.permitted = false, this.grant = true});
  @override
  Future<bool> hasPermission() async => permitted;
  @override
  Future<bool> requestPermission() async {
    asked++;
    permitted = grant;
    return grant;
  }

  @override
  Future<String?> getToken() async => 'fcm-1';
  @override
  Future<String> installationId() async => 'inst-1';
  @override
  String get platform => 'android';
  @override
  Future<void> openSettings() async => opened++;
}

void main() {
  group('API additions', () {
    test('memberSettings parses every field', () async {
      final f = Fake({'GET /v1/settings': (_) => settingsJson()});
      final s = await apiFor(f).memberSettings();
      expect(s.managed, isTrue);
      expect(s.preferencesLocked, isTrue);
      expect(s.inboxRetentionDays, 90);
      expect(s.pushEnabled, isTrue);
      expect(s.pushPrompt, 'after_first_notification');
      expect(s.pushExplanation, 'Get visitor alerts');
    });

    test('locked preference sends consent only; unlocked sends enabled', () {
      expect(ChannelPreference(channel: 'SMS', enabled: true, consent: false, locked: true).toJson(), {'channel': 'SMS', 'consent': false});
      expect(ChannelPreference(channel: 'SMS', enabled: false, consent: true).toJson(), {'channel': 'SMS', 'enabled': false, 'consent': true});
    });

    test('extraHeaders and forOrganization', () async {
      late http.BaseRequest seen;
      final c = MockClient((r) async {
        seen = r;
        return http.Response('{"count":1}', 200);
      });
      final api = NotificationApi(
          baseUrl: Uri.parse('https://x.test/'), organizationId: 'a', accessToken: () async => 't', client: c,
          productCode: 'cmm', extraHeaders: const {'X-Platform-Admin': 'true'});
      await api.forOrganization('b').unreadCount();
      expect(seen.headers['X-Organization-Id'], 'b');
      expect(seen.headers['X-Product-Code'], 'cmm');
      expect(seen.headers['X-Platform-Admin'], 'true');
    });
  });

  group('C1 NotificationPreferencesPage', () {
    testWidgets('managed organization: read-only channels, consent for SMS/WhatsApp', (t) async {
      var prefs = [
        {'channel': 'IN_APP', 'enabled': true, 'consent': true, 'locked': true},
        {'channel': 'PUSH', 'enabled': true, 'consent': true, 'locked': true},
        {'channel': 'SMS', 'enabled': true, 'consent': true, 'locked': true},
        {'channel': 'WHATSAPP', 'enabled': true, 'consent': false, 'locked': true},
      ];
      final f = Fake({
        'GET /v1/preferences': (_) => {'items': prefs, 'locked': true},
        'POST /v1/preferences': (r) {
          final it = (jsonDecode(r.body)['items'] as List).first as Map;
          prefs = [for (final p in prefs) p['channel'] == it['channel'] ? {...p, 'consent': it['consent']} : p];
          return {'items': prefs, 'locked': true};
        },
      });
      await t.pumpWidget(host(NotificationPreferencesPage(api: apiFor(f), organizationName: 'Green Meadows')));
      await t.pumpAndSettle();
      expect(find.text('Green Meadows chooses how you are notified.'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Always on'), findsOneWidget);
      expect(find.text('Set by your organization'), findsOneWidget); // PUSH
      expect(find.text('Waiting for your consent'), findsOneWidget); // WhatsApp
      await t.tap(find.text('Allow'));
      await t.pumpAndSettle();
      expect(find.text('Allow WhatsApp messages?'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, 'Allow'));
      await t.pumpAndSettle();
      expect(f.bodies('POST /v1/preferences').last, {'items': [{'channel': 'WHATSAPP', 'consent': true}]});
      await t.tap(find.text('Withdraw consent').first);
      await t.pumpAndSettle();
      expect(f.bodies('POST /v1/preferences').last['items'][0], {'channel': 'SMS', 'consent': false});
    });

    testWidgets('consent dialog "Not now" sends nothing', (t) async {
      final f = Fake({'GET /v1/preferences': (_) => {'items': [{'channel': 'SMS', 'enabled': true, 'consent': false, 'locked': true}], 'locked': true}});
      await t.pumpWidget(host(NotificationPreferencesPage(api: apiFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.text('Allow'));
      await t.pumpAndSettle();
      await t.tap(find.text('Not now'));
      await t.pumpAndSettle();
      expect(f.bodies('POST /v1/preferences'), isEmpty);
    });

    testWidgets('unmanaged organization: member switches channels', (t) async {
      final f = Fake({
        'GET /v1/preferences': (_) => {'items': [{'channel': 'PUSH', 'enabled': true, 'consent': true, 'locked': false}], 'locked': false},
        'POST /v1/preferences': (_) => {'items': [{'channel': 'PUSH', 'enabled': false, 'consent': false, 'locked': false}]},
      });
      await t.pumpWidget(host(NotificationPreferencesPage(api: apiFor(f))));
      await t.pumpAndSettle();
      expect(find.byType(Switch), findsOneWidget);
      await t.tap(find.byType(Switch));
      await t.pumpAndSettle();
      expect(f.bodies('POST /v1/preferences').last['items'][0], {'channel': 'PUSH', 'enabled': false, 'consent': false});
    });

    testWidgets('locked error shows a message; load error offers retry', (t) async {
      final f = Fake({
        'GET /v1/preferences': (_) => {'items': [{'channel': 'PUSH', 'enabled': true, 'consent': true, 'locked': false}]},
        'POST /v1/preferences': (_) => http.Response(jsonEncode({'error': 'preferences_locked'}), 403),
      });
      await t.pumpWidget(host(NotificationPreferencesPage(api: apiFor(f), organizationName: 'GM')));
      await t.pumpAndSettle();
      await t.tap(find.byType(Switch));
      await t.pumpAndSettle();
      expect(find.text('This channel is set by GM'), findsOneWidget);

      final bad = Fake({'GET /v1/preferences': (_) => http.Response('{}', 500)});
      await t.pumpWidget(host(NotificationPreferencesPage(api: apiFor(bad))));
      await t.pumpAndSettle();
      expect(find.text('Could not load settings. Retry'), findsOneWidget);
    });
  });

  group('C2 NotificationInboxPage', () {
    final now = DateTime.now();
    Map<String, dynamic> item(String id, {bool read = false, int daysAgo = 0, Map? action}) => {
          'id': id, 'title': 'T$id', 'body': 'B$id', if (read) 'read_at': now.toIso8601String(),
          'created_at': now.subtract(Duration(days: daysAgo)).toIso8601String(), if (action != null) 'action': action
        };

    testWidgets('pages, groups by day, unread filter, mark read + action, mark all', (t) async {
      final f = Fake({
        'GET /v1/settings': (_) => settingsJson(),
        'GET /v1/notifications': (r) => r.url.queryParameters['before'] == null
            ? {'items': [item('1', action: {'route': '/r'}), item('2', daysAgo: 1)], 'nextCursor': 'c1'}
            : {'items': [item('3', read: true, daysAgo: 9)], 'nextCursor': null},
        'POST /v1/notifications/1/read': (_) => {'ok': true},
        'POST /v1/notifications/mark-read': (_) => {'ok': true, 'updated': 2},
      });
      final actions = <Map>[];
      var changed = 0;
      await t.pumpWidget(host(NotificationInboxPage(api: apiFor(f), pageSize: 2, onAction: (a) async => actions.add(a), onChanged: () => changed++)));
      await t.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      await t.tap(find.text('Load older'));
      await t.pumpAndSettle();
      expect(find.text('T3'), findsOneWidget);
      expect(f.calls.any((c) => c.url.queryParameters['before'] == 'c1'), isTrue);
      await t.tap(find.text('T1'));
      await t.pumpAndSettle();
      expect(actions.single, {'route': '/r'});
      expect(changed, 1);
      await t.tap(find.text('Mark all read'));
      await t.pumpAndSettle();
      expect(f.bodies('POST /v1/notifications/mark-read').single, {'all': true});
      await t.tap(find.text('Unread'));
      await t.pumpAndSettle();
      expect(f.calls.last.url.queryParameters['unread'], 'true');
    });

    testWidgets('no day groups when the organization turns them off; empty and error states', (t) async {
      final f = Fake({'GET /v1/notifications': (_) => {'items': [item('1')], 'nextCursor': null}});
      await t.pumpWidget(host(NotificationInboxPage(api: apiFor(f), settings: MemberSettings.fromJson(settingsJson(groupByDay: false)))));
      await t.pumpAndSettle();
      expect(find.text('Today'), findsNothing);
      expect(f.calls.any((c) => c.url.path.endsWith('/v1/settings')), isFalse);

      final empty = Fake({'GET /v1/notifications': (_) => {'items': [], 'nextCursor': null}});
      await t.pumpWidget(host(NotificationInboxPage(api: apiFor(empty), settings: const MemberSettings())));
      await t.pumpAndSettle();
      expect(find.text('No notifications'), findsOneWidget);

      final bad = Fake({'GET /v1/notifications': (_) => http.Response('{}', 500)});
      await t.pumpWidget(host(NotificationInboxPage(api: apiFor(bad), settings: const MemberSettings())));
      await t.pumpAndSettle();
      expect(find.text('Could not load. Retry'), findsOneWidget);
    });

    test('day labels', () {
      final now = DateTime(2026, 11, 26, 18);
      expect(NotificationInboxPageState.dayLabel(DateTime(2026, 11, 26, 1), now), 'Today');
      expect(NotificationInboxPageState.dayLabel(DateTime(2026, 11, 25, 23), now), 'Yesterday');
      expect(NotificationInboxPageState.dayLabel(DateTime(2026, 11, 2), now), '2 Nov');
      expect(NotificationInboxPageState.dayLabel(DateTime(2025, 1, 5), now), '5 Jan 2025');
    });

    testWidgets('bell hides the badge when the organization turns it off', (t) async {
      final f = Fake({'GET /v1/notifications/unread-count': (_) => {'count': 4}});
      await t.pumpWidget(host(NotificationBell(api: apiFor(f), onPressed: () {}, showBadge: false)));
      await t.pump();
      await t.pump();
      expect(t.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
      await t.pumpWidget(host(NotificationBell(api: apiFor(f), onPressed: () {})));
      await t.pump();
      await t.pump();
      expect(t.widget<Badge>(find.byType(Badge)).isLabelVisible, isTrue);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('C3 NotificationPushHelper', () {
    Fake fake({String prompt = 'after_first_notification', bool push = true}) => Fake({
          'GET /v1/settings': (_) => settingsJson(prompt: prompt, push: push),
          'POST /v1/devices/register': (_) => {'ok': true},
          'POST /v1/devices/unregister': (_) => {'ok': true, 'updated': 1},
        });

    test('prompt only for the configured trigger, when push is on and not yet permitted', () async {
      expect(await NotificationPushHelper(api: apiFor(fake()), push: FakePush()).shouldPrompt('after_first_notification'), isTrue);
      expect(await NotificationPushHelper(api: apiFor(fake()), push: FakePush()).shouldPrompt('first_login'), isFalse);
      expect(await NotificationPushHelper(api: apiFor(fake(prompt: 'off')), push: FakePush()).shouldPrompt('off'), isFalse);
      expect(await NotificationPushHelper(api: apiFor(fake(push: false)), push: FakePush()).shouldPrompt('after_first_notification'), isFalse);
      expect(await NotificationPushHelper(api: apiFor(fake()), push: FakePush(permitted: true)).shouldPrompt('after_first_notification'), isFalse);
    });

    test('registerIfPermitted and unregister', () async {
      final f = fake();
      final h = NotificationPushHelper(api: apiFor(f), push: FakePush(permitted: true));
      expect(await h.registerIfPermitted(), isTrue);
      expect(f.bodies('POST /v1/devices/register').single, {'token': 'fcm-1', 'installationId': 'inst-1', 'platform': 'android'});
      await h.unregister();
      expect(f.bodies('POST /v1/devices/unregister').single, {'installationId': 'inst-1'});
      expect(await NotificationPushHelper(api: apiFor(fake()), push: FakePush()).registerIfPermitted(), isFalse);
    });

    Future<void> run(WidgetTester t, NotificationPushHelper h, String button, List<bool> out) async {
      await t.pumpWidget(host(Builder(builder: (ctx) => TextButton(onPressed: () async => out.add(await h.maybePrompt(ctx, trigger: 'after_first_notification')), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Get visitor alerts'), findsOneWidget); // organization's explanation
      await t.tap(find.text(button));
      await t.pumpAndSettle();
    }

    testWidgets('explain, grant, register', (t) async {
      final f = fake(), p = FakePush(), out = <bool>[];
      await run(t, NotificationPushHelper(api: apiFor(f), push: p), 'Turn on', out);
      expect(out, [true]);
      expect(p.asked, 1);
      expect(f.bodies('POST /v1/devices/register'), hasLength(1));
    });

    testWidgets('"Not now" never asks the OS', (t) async {
      final p = FakePush(), out = <bool>[];
      await run(t, NotificationPushHelper(api: apiFor(fake()), push: p), 'Not now', out);
      expect(out, [false]);
      expect(p.asked, 0);
    });

    testWidgets('denied permission offers system settings', (t) async {
      final f = fake(), p = FakePush(grant: false), out = <bool>[];
      await run(t, NotificationPushHelper(api: apiFor(f), push: p), 'Turn on', out);
      expect(out, [false]);
      expect(find.text('Notifications are off for this app'), findsOneWidget);
      await t.tap(find.text('Settings'));
      expect(p.opened, 1);
      expect(f.bodies('POST /v1/devices/register'), isEmpty);
    });
  });
}
