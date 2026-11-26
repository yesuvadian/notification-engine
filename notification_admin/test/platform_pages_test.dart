// Widget tests for the platform pages (D1-D6) and the designer (D5/B7): every option on each page.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notification_admin/notification_admin.dart';

import 'fake.dart';

Map<String, dynamic> product({String status = 'ACTIVE'}) => {
      'id': 'p1',
      'code': 'ass',
      'name': 'Astute Stay',
      'status': status,
      'organizations': 3,
      'issuers': [{'issuer': 'https://a.supabase.co/auth/v1', 'active': true}],
      'defaults': [
        {'channel': 'IN_APP', 'supported': true, 'default_enabled': true},
        {'channel': 'SMS', 'supported': true, 'default_enabled': false},
      ],
    };

void main() {
  group('D1 Products', () {
    testWidgets('lists products and saves channel defaults', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/products': (_) => [product()],
        'PUT /v1/platform/products/ass/channels': (_) => [],
      });
      await t.pumpWidget(host(ProductsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      expect(find.text('Astute Stay'), findsOneWidget);
      expect(find.text('3 organizations · 1 login issuers'), findsOneWidget);
      // Turn SMS on for new orgs, support PUSH, then save.
      await t.tap(find.byKey(const ValueKey('ass-SMS-default')));
      await t.tap(find.byKey(const ValueKey('ass-PUSH-supported')));
      await t.pump();
      await tapText(t, 'Save channels');
      final items = (f.bodies('PUT /v1/platform/products/ass/channels').single['items'] as List).cast<Map>();
      final sms = items.firstWhere((i) => i['channel'] == 'SMS');
      final push = items.firstWhere((i) => i['channel'] == 'PUSH');
      expect(sms['default_enabled'], true);
      expect(push['supported'], true);
      expect(find.text('Channel defaults saved'), findsOneWidget);
    });

    testWidgets('turning support off also turns off the default; IN_APP cannot change', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/products': (_) => [product()], 'PUT /v1/platform/products/ass/channels': (_) => []});
      await t.pumpWidget(host(ProductsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ass-SMS-default')));
      await t.tap(find.byKey(const ValueKey('ass-SMS-supported')));
      await t.pump();
      expect(t.widget<Switch>(find.byKey(const ValueKey('ass-SMS-default'))).value, isFalse);
      expect(t.widget<Switch>(find.byKey(const ValueKey('ass-IN_APP-supported'))).onChanged, isNull);
    });

    testWidgets('creates a product', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/products': (_) => [], 'POST /v1/platform/products': (_) => {'id': 'p2'}});
      await t.pumpWidget(host(ProductsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      await tapText(t, 'New product');
      await t.enterText(find.byKey(const ValueKey('product-code')), 'afd');
      await t.enterText(find.byKey(const ValueKey('product-name')), 'Field Desk');
      await tapText(t, 'Create');
      expect(f.bodies('POST /v1/platform/products').single, {'code': 'afd', 'name': 'Field Desk'});
    });

    testWidgets('suspends and activates a product', (t) async {
      await big(t);
      var status = 'ACTIVE';
      final f = FakeEngine({
        'GET /v1/platform/products': (_) => [product(status: status)],
        'POST /v1/platform/products/ass/status': (r) {
          status = status == 'ACTIVE' ? 'SUSPENDED' : 'ACTIVE';
          return {};
        },
      });
      await t.pumpWidget(host(ProductsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      await tapText(t, 'Suspend');
      expect(f.bodies('POST /v1/platform/products/ass/status').single['active'], false);
      expect(find.text('Suspended'), findsOneWidget);
      await tapText(t, 'Activate');
      expect(f.bodies('POST /v1/platform/products/ass/status').last['active'], true);
    });

    testWidgets('tokens: create shows the token once, revoke removes it', (t) async {
      await big(t);
      var tokens = <Map<String, dynamic>>[];
      final f = FakeEngine({
        'GET /v1/platform/products': (_) => [product()],
        'GET /v1/platform/products/ass/tokens': (_) => tokens,
        'POST /v1/platform/products/ass/tokens': (_) {
          tokens = [{'id': 'k1', 'label': 'console', 'expires_at': '2027-02-24'}];
          return {'token': 'ntf_secret_abc', 'id': 'k1'};
        },
        'DELETE /v1/platform/tokens/k1': (_) {
          tokens = [{'id': 'k1', 'label': 'console', 'revoked_at': 'now'}];
          return {};
        },
      });
      await t.pumpWidget(host(ProductsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      await tapText(t, 'Tokens');
      expect(find.text('No tokens'), findsOneWidget);
      await tapText(t, 'Create token');
      expect(find.text('ntf_secret_abc'), findsOneWidget);
      await tapText(t, 'Revoke');
      expect(f.hits('DELETE /v1/platform/tokens/k1'), hasLength(1));
      expect(find.text('Revoked'), findsOneWidget);
    });

    testWidgets('issuers: saves an issuer with audience and optional JWKS', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/products': (_) => [product()],
        'GET /v1/platform/products/ass/issuers': (_) => [],
        'POST /v1/platform/products/ass/issuers': (_) => {},
      });
      await t.pumpWidget(host(ProductsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      await tapText(t, 'Issuers');
      await t.enterText(find.byKey(const ValueKey('issuer')), 'https://b.supabase.co/auth/v1');
      await tapText(t, 'Save issuer');
      expect(f.bodies('POST /v1/platform/products/ass/issuers').single, {'issuer': 'https://b.supabase.co/auth/v1', 'audience': 'authenticated'});
    });
  });

  group('D2 Organizations', () {
    Map<String, dynamic> org({bool active = true, bool managed = true}) => {
          'organization_id': 'o1',
          'name': 'Green PG',
          'active': active,
          'managed': managed,
          'users': 12,
          'sent_7d': 40,
          'channels': ['IN_APP', 'SMS'],
        };

    testWidgets('lists, searches and filters', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/organizations': (_) => [org(managed: false)]});
      await t.pumpWidget(host(OrganizationsPage(api: platformFor(f), productCode: 'ass')));
      await t.pumpAndSettle();
      expect(find.text('Green PG'), findsOneWidget);
      expect(find.text('12 members · 40 deliveries in 7 days'), findsOneWidget);
      expect(find.text('Not provisioned by console'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('org-search')), 'green');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(f.calls.last.url.queryParameters['search'], 'green');
      await tapText(t, 'Inactive');
      expect(f.calls.last.url.queryParameters['status'], 'inactive');
    });

    testWidgets('suspend needs a reason; cancel sends nothing', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/organizations': (_) => [org()], 'POST /v1/platform/organizations/status': (_) => {}});
      await t.pumpWidget(host(OrganizationsPage(api: platformFor(f), productCode: 'ass')));
      await t.pumpAndSettle();
      await tapText(t, 'Suspend');
      await tapText(t, 'Cancel');
      expect(f.hits('POST /v1/platform/organizations/status'), isEmpty);
      await tapText(t, 'Suspend');
      await tapText(t, 'Suspend'); // empty reason: stays open
      expect(f.hits('POST /v1/platform/organizations/status'), isEmpty);
      await t.enterText(find.byType(TextField).last, 'Unpaid');
      await tapText(t, 'Suspend');
      expect(f.bodies('POST /v1/platform/organizations/status').single,
          {'productCode': 'ass', 'organizationId': 'o1', 'active': false, 'reason': 'Unpaid'});
    });

    testWidgets('reactivates without a reason', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/organizations': (_) => [org(active: false)], 'POST /v1/platform/organizations/status': (_) => {}});
      await t.pumpWidget(host(OrganizationsPage(api: platformFor(f), productCode: 'ass')));
      await t.pumpAndSettle();
      await tapText(t, 'Reactivate');
      expect(f.bodies('POST /v1/platform/organizations/status').single['active'], true);
    });

    testWidgets('Manage calls the console navigation', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/organizations': (_) => [org()]});
      String? opened;
      await t.pumpWidget(host(OrganizationsPage(api: platformFor(f), productCode: 'ass', onOpen: (c, p, id, n) => opened = '$p/$id/$n')));
      await t.pumpAndSettle();
      await tapText(t, 'Manage');
      expect(opened, 'ass/o1/Green PG');
    });

    testWidgets('new organization pre-fills product defaults and provisions the choices', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/organizations': (_) => [],
        'GET /v1/platform/groups': (_) => [{'group': 'PAYMENTS'}, {'group': 'VISITORS'}],
        'GET /v1/platform/products': (_) => [
              {
                ...product(),
                'defaults': [
                  {'channel': 'SMS', 'supported': true, 'default_enabled': true},
                  {'channel': 'PUSH', 'supported': true, 'default_enabled': false},
                  {'channel': 'WHATSAPP', 'supported': false, 'default_enabled': false},
                ]
              }
            ],
        'POST /v1/platform/organizations': (_) => {'tenantId': 't1'},
      });
      await t.pumpWidget(host(OrganizationsPage(api: platformFor(f), productCode: 'ass')));
      await t.pumpAndSettle();
      await tapText(t, 'New organization');
      expect(t.widget<Checkbox>(find.byKey(const ValueKey('pref-PAYMENTS-SMS'))).value, isTrue);
      expect(t.widget<Checkbox>(find.byKey(const ValueKey('pref-PAYMENTS-WHATSAPP'))).onChanged, isNull);
      expect(t.widget<Checkbox>(find.byKey(const ValueKey('pref-PAYMENTS-IN_APP'))).onChanged, isNull);
      await t.tap(find.byKey(const ValueKey('pref-VISITORS-PUSH')));
      await t.tap(find.byKey(const ValueKey('pref-PAYMENTS-SMS')));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('org-name')), 'Green PG');
      await t.enterText(find.byKey(const ValueKey('org-id')), '11111111-1111-4111-8111-111111111111');
      await t.enterText(find.byKey(const ValueKey('push-text')), 'Visitor alerts at the gate');
      await tapText(t, 'Create organization');
      final b = f.bodies('POST /v1/platform/organizations').single;
      expect(b['organizationName'], 'Green PG');
      expect(b['preferences'], {
        'PAYMENTS': ['IN_APP'],
        'VISITORS': ['IN_APP', 'SMS', 'PUSH']
      });
      expect(b['settings'], {'inbox_retention_days': 90, 'push_prompt': 'after_first_notification', 'push_explanation': 'Visitor alerts at the gate'});
      expect(find.text('Organization created'), findsOneWidget);
    });

    testWidgets('new organization shows the engine error and stays open', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/organizations': (_) => [],
        'GET /v1/platform/groups': (_) => [],
        'GET /v1/platform/products': (_) => [product()],
        'POST /v1/platform/organizations': (_) => err(409, 'conflict', 'Organization is already provisioned'),
      });
      await t.pumpWidget(host(OrganizationsPage(api: platformFor(f), productCode: 'ass')));
      await t.pumpAndSettle();
      await tapText(t, 'New organization');
      await tapText(t, 'Create organization');
      expect(find.text('Organization is already provisioned'), findsOneWidget);
      expect(find.text('Create organization'), findsOneWidget);
    });
  });

  group('D3 Channels', () {
    testWidgets('saves the secret to Vault first, then the config, and clears the secret field', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/channels': (_) => [
              {'channel': 'SMS', 'configured': false, 'hasSecret': false, 'provider_config': {}},
            ],
        'PUT /v1/platform/channels/SMS/secret': (_) => {'ok': true, 'secret_name': 'ntf_shared_sms'},
        'PUT /v1/platform/channels/SMS': (_) => {},
      });
      await t.pumpWidget(host(PlatformChannelsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      expect(find.text('Not configured (mock)'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('SMS-provider')));
      await t.pumpAndSettle();
      await t.tap(find.text('msg91').last);
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('SMS-template_id')), 'tpl-77');
      await t.enterText(find.byKey(const ValueKey('SMS-secret-authkey')), 'k-123');
      await tapText(t, 'Save');
      final order = f.calls.where((c) => c.method == 'PUT').map((c) => c.url.path.split('/').last).toList();
      expect(order, ['secret', 'SMS']);
      expect(f.bodies('PUT /v1/platform/channels/SMS/secret').single, {'value': {'authkey': 'k-123'}});
      expect(f.bodies('PUT /v1/platform/channels/SMS').single, {'provider_config': {'provider': 'msg91', 'template_id': 'tpl-77'}});
    });

    testWidgets('http provider sends headers and body JSON; no secret call when empty', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/channels': (_) => [
              {'channel': 'SMS', 'configured': true, 'hasSecret': true, 'provider_config': {'provider': 'http', 'url': 'https://sms.example/send'}},
            ],
        'PUT /v1/platform/channels/SMS': (_) => {},
      });
      await t.pumpWidget(host(PlatformChannelsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      expect(find.text('Configured · http'), findsOneWidget);
      expect(find.text('Credentials stored'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('SMS-headers')), '{"Authorization": "Bearer {{secret.api_key}}"}');
      await t.enterText(find.byKey(const ValueKey('SMS-body')), '{"to": "{{to}}"}');
      await tapText(t, 'Save');
      expect(f.hits('PUT /v1/platform/channels/SMS/secret'), isEmpty);
      final cfg = f.bodies('PUT /v1/platform/channels/SMS').single['provider_config'];
      expect(cfg['url'], 'https://sms.example/send');
      expect(cfg['headers'], {'Authorization': 'Bearer {{secret.api_key}}'});
      expect(cfg['body'], {'to': '{{to}}'});
    });

    testWidgets('test send: phone for SMS, device token for PUSH, error shown', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/channels': (_) => [
              {'channel': 'SMS', 'configured': true, 'provider_config': {'provider': 'mock'}},
              {'channel': 'PUSH', 'configured': false, 'provider_config': {}},
            ],
        'POST /v1/platform/channels/SMS/test': (_) => {'outcome': 'SENT', 'provider': 'mock'},
        'POST /v1/platform/channels/PUSH/test': (_) => err(409, 'not_configured', 'Push is not configured'),
      });
      await t.pumpWidget(host(PlatformChannelsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('SMS-test-to')), '+919800000000');
      await t.tap(find.text('Send test').first);
      await t.pumpAndSettle();
      expect(f.bodies('POST /v1/platform/channels/SMS/test').single, {'phone': '+919800000000'});
      expect(find.text('Test send: SENT via mock'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('PUSH-test-to')), 'dev-token');
      await t.tap(find.text('Send test').last);
      await t.pumpAndSettle();
      expect(f.bodies('POST /v1/platform/channels/PUSH/test').single, {'deviceToken': 'dev-token'});
      expect(find.text('Push is not configured'), findsOneWidget);
    });
  });

  group('D4 Templates', () {
    Map<String, dynamic> tpl() => {
          'id': 't1',
          'code': 'RENT_DUE',
          'name': 'Rent due',
          'product_id': null,
          'latestPublished': 1,
          'organizationsWithOverrides': 2,
          'pinnedOrganizations': {'1': 4},
          'versions': [
            {'version': 1, 'channel': 'IN_APP', 'status': 'PUBLISHED', 'content': {'title': 'Rent', 'body': 'Due'}},
            {'version': 2, 'channel': 'IN_APP', 'status': 'DRAFT', 'content': {'title': 'Rent', 'body': 'Due soon'}},
          ],
        };

    testWidgets('shows versions and usage; publishes a draft', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/templates': (_) => [tpl()], 'POST /v1/platform/templates/t1/versions/2/publish': (_) => {}});
      await t.pumpWidget(host(PlatformTemplatesPage(api: platformFor(f))));
      await t.pumpAndSettle();
      expect(find.textContaining('new organizations start on v1'), findsOneWidget);
      expect(find.textContaining('2 organizations with overrides'), findsOneWidget);
      expect(find.text('v1 published · 4 orgs · In-app'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('RENT_DUE-v2')));
      await t.pumpAndSettle();
      await tapText(t, 'Publish');
      expect(f.hits('POST /v1/platform/templates/t1/versions/2/publish'), hasLength(1));
    });

    testWidgets('retire shows the engine refusal when the version is in use', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/templates': (_) => [tpl()],
        'POST /v1/platform/templates/t1/versions/1/retire': (_) => err(409, 'version_in_use', '4 organizations still use v1'),
      });
      await t.pumpWidget(host(PlatformTemplatesPage(api: platformFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('RENT_DUE-v1')));
      await t.pumpAndSettle();
      await tapText(t, 'Retire');
      expect(find.text('4 organizations still use v1'), findsOneWidget);
    });

    testWidgets('creates a template with an upper-case code for the product', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/templates': (_) => [], 'POST /v1/platform/templates': (_) => {'id': 't9'}});
      await t.pumpWidget(host(PlatformTemplatesPage(api: platformFor(f), productCode: 'ass')));
      await t.pumpAndSettle();
      await tapText(t, 'New template');
      await t.enterText(find.byKey(const ValueKey('tpl-code')), 'visitor_arrived');
      await t.enterText(find.byKey(const ValueKey('tpl-name')), 'Visitor arrived');
      await tapText(t, 'Create');
      final b = f.bodies('POST /v1/platform/templates').single;
      expect(b['code'], 'VISITOR_ARRIVED');
      expect(b['name'], 'Visitor arrived');
      expect(b['productCode'], 'ass');
    });

    testWidgets('Open goes to the designer', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/templates': (_) => [tpl()]});
      await t.pumpWidget(host(PlatformTemplatesPage(api: platformFor(f))));
      await t.pumpAndSettle();
      await tapText(t, 'Open');
      expect(find.byType(TemplateDesigner), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('field-body'))).controller!.text, 'Due soon'); // draft wins
    });
  });

  group('D5 Designer (platform)', () {
    Map<String, dynamic> tpl() => {
          'id': 't1',
          'code': 'RENT_DUE',
          'versions': [
            {'version': 1, 'channel': 'IN_APP', 'status': 'PUBLISHED', 'content': {'title': 'Rent for {{data.flat}}', 'body': 'Pay {{data.amount | number}}'}},
          ],
        };

    testWidgets('live preview, variable insert and missing variables', (t) async {
      await big(t);
      final f = FakeEngine({});
      await t.pumpWidget(host(TemplateDesigner.platform(api: platformFor(f), template: tpl())));
      await t.pumpAndSettle();
      expect(find.text('Rent for B-402'), findsOneWidget);
      expect(find.text('Pay 12,500'), findsOneWidget);
      expect(find.byKey(const ValueKey('vars-ok')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('var-data.reference')));
      await t.pump();
      expect(t.widget<TextField>(find.byKey(const ValueKey('field-body'))).controller!.text, 'Pay {{data.amount | number}}{{data.reference}}');
      await t.enterText(find.byKey(const ValueKey('field-body')), 'Hi {{data.unknown}}');
      await t.pump();
      expect(find.text('Missing: data.unknown'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('sample')), '{bad');
      await t.pump();
      expect(find.text('Sample data is not valid JSON'), findsOneWidget);
    });

    testWidgets('SMS shows the segment count', (t) async {
      await big(t);
      await t.pumpWidget(host(TemplateDesigner.platform(api: platformFor(FakeEngine({})), template: tpl(), initialChannel: 'SMS')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('field-body')), 'x' * 170);
      await t.pump();
      expect(find.text('170 characters · 2 SMS segments'), findsOneWidget);
    });

    testWidgets('save draft then publish it; publish without a draft asks for one', (t) async {
      await big(t);
      final f = FakeEngine({
        'POST /v1/platform/templates/t1/versions': (_) => {'version': 2, 'channel': 'IN_APP', 'status': 'DRAFT', 'content': {'title': 'New', 'body': 'Pay'}},
        'POST /v1/platform/templates/t1/versions/2/publish': (_) => {},
      });
      final template = tpl();
      await t.pumpWidget(host(TemplateDesigner.platform(api: platformFor(f), template: template)));
      await t.pumpAndSettle();
      await tapText(t, 'Publish');
      expect(find.text('Save a draft first'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('field-title')), 'New');
      await tapText(t, 'Save draft');
      final b = f.bodies('POST /v1/platform/templates/t1/versions').single;
      expect(b['channel'], 'IN_APP');
      expect(b['content']['title'], 'New');
      await tapText(t, 'Publish');
      await tapText(t, 'Publish');
      expect(f.hits('POST /v1/platform/templates/t1/versions/2/publish'), hasLength(1));
      expect((template['versions'] as List).where((v) => v['version'] == 2).single['status'], 'PUBLISHED');
    });
  });

  group('D6 Operations and audit', () {
    testWidgets('queues, dead letters and replay', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/ops': (_) => {
              'queues': [{'queue_name': 'ntf_deliveries', 'queue_length': 3, 'oldest_msg_age_sec': 12}],
              'deadLetters': [
                {'enqueued_at': '2026-11-26T10:00:00Z', 'message': {'reason': 'Provider 500', 'source_queue': 'ntf_deliveries', 'delivery_id': 'd1'}},
                {'enqueued_at': '2026-11-26T10:01:00Z', 'message': {'reason': 'Bad event'}},
              ],
            },
        'POST /v1/platform/deliveries/d1/replay': (_) => {},
      });
      await t.pumpWidget(host(OperationsPage(api: platformFor(f))));
      await t.pumpAndSettle();
      expect(find.text('3 waiting · oldest 12s'), findsOneWidget);
      expect(find.text('Replay'), findsOneWidget); // only the one with a delivery id
      await tapText(t, 'Replay');
      expect(f.hits('POST /v1/platform/deliveries/d1/replay'), hasLength(1));
    });

    testWidgets('audit lists platform actions only', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/platform/audit': (_) => [{'action': 'platform.organization.create', 'actor': 'admin@x', 'created_at': 'now'}]});
      await t.pumpWidget(host(PlatformAuditPage(api: platformFor(f))));
      await t.pumpAndSettle();
      expect(find.text('platform.organization.create'), findsOneWidget);
      expect(f.calls.single.url.queryParameters['platformOnly'], 'true');
    });
  });

  group('Module', () {
    test('canAdminister is false for 401/403 and rethrows other errors', () async {
      for (final s in [401, 403]) {
        final m = NotificationAdminModule(api: platformFor(FakeEngine({'GET /v1/platform/overview': (_) => err(s, 'forbidden', 'no')})), productCode: 'ass');
        expect(await m.canAdminister(), isFalse);
      }
      final m = NotificationAdminModule(api: platformFor(FakeEngine({'GET /v1/platform/overview': (_) => err(500, 'internal', 'boom')})), productCode: 'ass');
      await expectLater(m.canAdminister(), throwsA(isA<Object>()));
    });

    testWidgets('menu builds every page and the overview card counts queues', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/platform/overview': (_) => {
              'products': 4,
              'organizations': 17,
              'queues': [
                {'queue_name': 'ntf_events', 'queue_length': 5},
                {'queue_name': 'ntf_dlq', 'queue_length': 2},
              ]
            },
      });
      final m = NotificationAdminModule(api: platformFor(f), productCode: 'ass');
      expect(m.productMenu.map((e) => e.label), ['Organizations']);
      expect(m.engineMenu.map((e) => e.label), ['Products', 'Channels', 'Templates', 'Operations', 'Audit']);
      expect(m.menu, hasLength(6));
      expect(await t.runAsync(m.canAdminister), isTrue);
      await t.pumpWidget(host(m.overviewCard()));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('ov-Organizations'))).data, '17');
      expect(t.widget<Text>(find.byKey(const ValueKey('ov-Queued'))).data, '5');
      expect(t.widget<Text>(find.byKey(const ValueKey('ov-Dead letters'))).data, '2');
      for (final item in m.menu) {
        await t.pumpWidget(host(Builder(builder: item.builder)));
        await t.pump();
      }
    });
  });
}
