// Integration tests against a running engine (local stack only). Skipped unless NTF_IT_URL is set, e.g.
//   NTF_IT_URL=http://127.0.0.1:8000/ NTF_IT_TOKEN=local-platform-only flutter test test/integration_test.dart
// Uses the seed's platform token and product_a; creates a fresh organization each run.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:notification_admin/notification_admin.dart';
import 'package:notification_sdk/notification_sdk.dart';

void main() {
  final url = Platform.environment['NTF_IT_URL'];
  final skip = url == null ? 'Set NTF_IT_URL to run against a local engine' : null;
  late NotificationPlatformApi api;
  late NotificationApi org;
  final orgId = newUuid();
  const product = 'product_a';
  late String group;

  setUpAll(() {
    if (url == null) return;
    // Real HTTP (flutter_test blocks it by default).
    HttpOverrides.global = null;
    api = NotificationPlatformApi(
        baseUrl: Uri.parse(url.endsWith('/') ? url : '$url/'),
        accessToken: () async => Platform.environment['NTF_IT_TOKEN'] ?? 'local-platform-only',
        client: http.Client());
    org = api.organization(product, orgId);
  });

  Future<void> expectStatus(Future<void> Function() f, int status) async {
    try {
      await f();
      fail('expected $status');
    } on NotificationApiException catch (e) {
      expect(e.status, status, reason: '${e.code} ${e.message}');
    }
  }

  test('overview and products', () async {
    final o = await api.overview();
    expect(o['products'], greaterThan(0));
    expect((await api.products()).map((p) => p['code']), contains(product));
  }, skip: skip);

  test('provision an organization with preferences and member app settings', () async {
    final groups = await api.groups(product);
    expect(groups, isNotEmpty);
    group = groups.first['group'] as String;
    final setup = NotificationSetup()
      ..inboxRetentionDays = 90
      ..pushExplanation = 'Integration';
    await provisionNotifications(api, productCode: product, organizationId: orgId, organizationName: 'IT org $orgId', setup: setup, groups: [group]);
    await expectStatus(
        () => provisionNotifications(api, productCode: product, organizationId: orgId, organizationName: 'again', setup: setup, groups: [group]), 409);
    final found = await api.organizations(product, search: 'IT org $orgId');
    expect(found.single['managed'], true);
  }, skip: skip);

  test('workspace: settings are add-only', () async {
    final s = await org.orgSettings();
    expect(s['managed'], true);
    expect(s['settings']['inbox_retention_days'], 90);
    await expectStatus(() => org.saveOrgSettings({'inbox_retention_days': 30}), 403);
    final raised = await org.saveOrgSettings({'inbox_retention_days': 180, 'group_by_day': true});
    expect(raised['settings']['inbox_retention_days'], 180);
  }, skip: skip);

  test('workspace: channels and preferences only grow', () async {
    await org.setChannelEnabled('SMS', true);
    final added = await org.addOrgPreferences([{'group': group, 'channel': 'SMS'}]);
    final g = (added['groups'] as List).cast<Map>().firstWhere((x) => x['group'] == group);
    expect((g['channels'] as List).map((c) => c['channel']), containsAll(['IN_APP', 'SMS']));
    await expectStatus(() => org.setChannelEnabled('SMS', false), 403);
  }, skip: skip);

  test('workspace: rule create, toggle and delete', () async {
    final events = await org.adminList('events');
    final rule = await org.createRule({
      'event_code': events.first['code'],
      'event_version': events.first['version'] ?? 1,
      'recipient_strategy': 'ALL_ORG_USERS',
      'purpose': 'TRANSACTIONAL',
      'active': false,
    });
    expect((await org.adminList('rules')).map((r) => r['id']), contains(rule['id']));
    await org.updateRule(rule['id'] as String, {'active': true});
    await org.deleteRule(rule['id'] as String);
    expect((await org.adminList('rules')).map((r) => r['id']), isNot(contains(rule['id'])));
  }, skip: skip);

  test('copy model: a shared template copied to the product, then set up in the organization', () async {
    final code = 'IT_COPY_${orgId.substring(0, 8).toUpperCase()}';
    final shared = await api.createTemplate(code, 'IT copy');
    await api.saveDraft(shared['id'] as String, 'IN_APP', {'title': 'Hi', 'body': '{{data.body}}'});
    await api.publishVersion(shared['id'] as String, 1);
    final listed = (await api.templates(productCode: product)).firstWhere((t) => t['id'] == shared['id']);
    final copy = await copyTemplateToProduct(api, listed, product);
    final mine = (await api.templates(productCode: product)).firstWhere((t) => t['id'] == copy['id']);
    expect(mine['product_id'], isNotNull);
    expect(mine['latestPublished'], 1);
    expect((mine['versions'] as List).single['content'], {'title': 'Hi', 'body': '{{data.body}}'});

    // Set up: every event without an active rule gets one, bound at the latest published version.
    final before = await loadRules(org);
    final r = await setUpNotifications(org, strategy: 'ALL_ORG_USERS');
    expect(r.created + r.failed.length, setupPlan(before, product).length);
    final after = await loadRules(org);
    expect(setupPlan(after, product).values.where((v) => v != null), isEmpty);
  }, skip: skip);

  test('suspend needs a reason, then reactivate; both are audited', () async {
    await expectStatus(() => api.setOrganizationActive(product, orgId, false), 422);
    await api.setOrganizationActive(product, orgId, false, reason: 'integration test');
    expect((await api.organizations(product, search: 'IT org $orgId', status: 'inactive')), hasLength(1));
    await api.setOrganizationActive(product, orgId, true);
    final audit = await api.audit();
    expect(audit.map((a) => a['action']), containsAll(['platform.organization.create', 'platform.organization.status']));
    expect((await org.adminList('audit')).map((a) => a['action']), contains('org_preferences.add'));
  }, skip: skip);
}
