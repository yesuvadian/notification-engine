// Unit tests: platform client headers and routes, organization client, preview rendering, setup JSON, helpers.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notification_admin/notification_admin.dart';
import 'package:notification_sdk/notification_sdk.dart';

import 'fake.dart';

void main() {
  group('NotificationPlatformApi', () {
    test('sends the super admin token and X-Platform-Admin on every call', () async {
      final f = FakeEngine({'GET /v1/platform/overview': (_) => {'products': 2, 'organizations': 5, 'queues': []}});
      final o = await platformFor(f).overview();
      expect(o['organizations'], 5);
      final h = f.calls.single.headers;
      expect(h['Authorization'], 'Bearer admin-jwt');
      expect(h['X-Platform-Admin'], 'true');
    });

    test('requires HTTPS except for local development hosts', () {
      expect(() => NotificationPlatformApi(baseUrl: Uri.parse('http://example.com/'), accessToken: () async => 't'), throwsArgumentError);
      expect(NotificationPlatformApi(baseUrl: Uri.parse('http://localhost:54321/'), accessToken: () async => 't'), isNotNull);
    });

    test('maps engine errors to NotificationApiException with the code and message', () async {
      final f = FakeEngine({'POST /v1/platform/products': (_) => err(409, 'conflict', 'Product exists')});
      await expectLater(
          platformFor(f).createProduct('ass', 'Astute Stay'),
          throwsA(isA<NotificationApiException>()
              .having((e) => e.status, 'status', 409)
              .having((e) => e.code, 'code', 'conflict')
              .having((e) => errorText(e), 'text', 'Product exists')));
    });

    test('organization() scopes calls with X-Product-Code, X-Organization-Id and X-Platform-Admin', () async {
      final f = FakeEngine({'GET /v1/admin/org-settings': (_) => {'managed': true, 'settings': {}}});
      await platformFor(f).organization('ass', 'org-9').orgSettings();
      final h = f.calls.single.headers;
      expect(h['X-Platform-Admin'], 'true');
      expect(h['X-Organization-Id'], 'org-9');
      expect(h['X-Product-Code'], 'ass');
    });

    test('organization list passes search and status filters', () async {
      final f = FakeEngine({'GET /v1/platform/organizations': (_) => []});
      await platformFor(f).organizations('ass', search: 'green', status: 'inactive');
      final q = f.calls.single.url.queryParameters;
      expect(q['product'], 'ass');
      expect(q['search'], 'green');
      expect(q['status'], 'inactive');
    });

    test('createOrganization posts preferences and settings', () async {
      final f = FakeEngine({'POST /v1/platform/organizations': (_) => {'tenantId': 't1'}});
      final setup = NotificationSetup()..toggle('PAYMENTS', 'SMS', true);
      await provisionNotifications(platformFor(f),
          productCode: 'ass', organizationId: 'o1', organizationName: 'Green PG', setup: setup, groups: ['PAYMENTS', 'VISITORS']);
      final b = f.bodies('POST /v1/platform/organizations').single;
      expect(b['productCode'], 'ass');
      expect(b['organizationId'], 'o1');
      expect(b['preferences'], {
        'PAYMENTS': ['IN_APP', 'SMS'],
        'VISITORS': ['IN_APP']
      });
      expect(b['settings']['push_prompt'], 'off');
    });
  });

  test('network failures say the engine could not be reached', () async {
    final api = NotificationPlatformApi(
        baseUrl: Uri.parse('https://x.test/'),
        accessToken: () async => 't',
        client: MockClient((_) async => throw http.ClientException('XMLHttpRequest error.')));
    try {
      await api.products();
      fail('expected an error');
    } catch (e) {
      expect(errorText(e), startsWith('Could not reach the notification engine'));
    }
  });

  group('renderPreview', () {
    final data = {
      'recipient': {'name': 'Anita Rao'},
      'data': {'amount': 1250000, 'flat': 'b-402'}
    };
    test('substitutes paths', () => expect(renderPreview('Hi {{recipient.name}}', data).text, 'Hi Anita Rao'));
    test('uppercase and lowercase', () {
      expect(renderPreview('{{data.flat | uppercase}}', data).text, 'B-402');
      expect(renderPreview('{{recipient.name | lowercase}}', data).text, 'anita rao');
    });
    test('number uses Indian grouping', () {
      expect(renderPreview('{{data.amount | number}}', data).text, '12,50,000');
      expect(renderPreview('{{data.amount | number}}', {'data': {'amount': 12500}}).text, '12,500');
    });
    test('default fills a missing value without reporting it', () {
      final r = renderPreview('{{data.note | default:"none"}}', data);
      expect(r.text, 'none');
      expect(r.missing, isEmpty);
    });
    test('reports missing variables', () {
      final r = renderPreview('Ref {{data.reference}}', data);
      expect(r.text, 'Ref ⟨data.reference⟩');
      expect(r.missing, ['data.reference']);
    });
  });

  test('smsInfo counts GSM segments', () {
    expect(smsInfo('a' * 160), '160 characters · 1 SMS segment');
    expect(smsInfo('a' * 161), '161 characters · 2 SMS segments');
  });

  group('NotificationSetup', () {
    test('IN_APP is always on and cannot be toggled', () {
      final s = NotificationSetup()..toggle('A', 'IN_APP', false);
      expect(s.has('A', 'IN_APP'), isTrue);
    });
    test('push prompt is sent only when a group uses push', () {
      final s = NotificationSetup()..pushPrompt = 'first_login';
      expect(s.settingsJson()['push_prompt'], 'off');
      s.toggle('A', 'PUSH', true);
      expect(s.settingsJson()['push_prompt'], 'first_login');
    });
    test('explanation is trimmed and omitted when blank', () {
      final s = NotificationSetup()..pushExplanation = '  ';
      expect(s.settingsJson().containsKey('push_explanation'), isFalse);
      s.pushExplanation = ' Alerts ';
      expect(s.settingsJson()['push_explanation'], 'Alerts');
    });
  });

  test('newUuid gives RFC 4122 v4 ids', () {
    final re = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    for (var i = 0; i < 20; i++) {
      expect(re.hasMatch(newUuid()), isTrue);
    }
  });

  test('RulesData.templatesFor keeps the latest published version per template', () {
    final d = RulesData([], [], [], [
      {'template_id': 't1', 'version': 1, 'channel': 'SMS', 'status': 'PUBLISHED', 'template': {'name': 'Pay'}},
      {'template_id': 't1', 'version': 2, 'channel': 'SMS', 'status': 'PUBLISHED', 'template': {'name': 'Pay'}},
      {'template_id': 't1', 'version': 3, 'channel': 'SMS', 'status': 'DRAFT', 'template': {'name': 'Pay'}},
      {'template_id': 't2', 'version': 1, 'channel': 'PUSH', 'status': 'PUBLISHED', 'template': {'code': 'VIS'}},
    ], [
      {'channel': 'SMS', 'enabled': true},
      {'channel': 'PUSH', 'enabled': false},
    ]);
    expect(d.templatesFor('SMS').single['version'], 2);
    expect(d.enabledChannels, ['SMS']);
    expect(d.templateName('t2'), 'VIS');
  });
}
