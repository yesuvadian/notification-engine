// Widget tests for the organization workspace (B2-B6, C1-C3 admin side) and the override designer (B7).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notification_admin/notification_admin.dart';
import 'package:notification_sdk/notification_sdk.dart';

import 'fake.dart';

NotificationApi orgFor(FakeEngine f) => platformFor(f).organization('ass', 'o1');

const rule = {
  'id': 'r1',
  'event_code': 'RENT_DUE',
  'recipient_strategy': 'ALL_USERS_IN_ROLE',
  'role_code': 'TENANT',
  'purpose': 'TRANSACTIONAL',
  'active': false,
};
const versions = [
  {'template_id': 't1', 'version': 1, 'channel': 'IN_APP', 'status': 'PUBLISHED', 'template': {'name': 'Rent due'}},
  {'template_id': 't1', 'version': 2, 'channel': 'IN_APP', 'status': 'PUBLISHED', 'template': {'name': 'Rent due'}},
  {'template_id': 't1', 'version': 1, 'channel': 'SMS', 'status': 'PUBLISHED', 'template': {'name': 'Rent due'}},
];

Map<String, dynamic Function(dynamic)> rulesRoutes({List<Map<String, dynamic>>? rules, List<Map<String, dynamic>>? bindings}) => {
      'GET /v1/admin/rules': (_) => rules ?? [Map<String, dynamic>.from(rule)],
      'GET /v1/admin/rule-channels': (_) => bindings ?? [],
      'GET /v1/admin/events': (_) => [{'code': 'RENT_DUE'}, {'code': 'VISITOR_ARRIVED'}],
      'GET /v1/admin/templates': (_) => versions,
      'GET /v1/admin/channels': (_) => [
            {'channel': 'IN_APP', 'enabled': true},
            {'channel': 'SMS', 'enabled': true},
            {'channel': 'PUSH', 'enabled': false},
          ],
    };

void main() {
  testWidgets('workspace shows all six tabs and every call carries the organization headers', (t) async {
    await big(t);
    final f = FakeEngine({...rulesRoutes()});
    await t.pumpWidget(host(OrganizationWorkspace(api: platformFor(f), productCode: 'ass', organizationId: 'o1', organizationName: 'Green PG')));
    await t.pumpAndSettle();
    for (final tab in OrganizationWorkspace.tabs) {
      expect(find.text(tab), findsWidgets);
    }
    expect(f.calls, isNotEmpty);
    for (final c in f.calls) {
      expect(c.headers['X-Organization-Id'], 'o1');
      expect(c.headers['X-Product-Code'], 'ass');
      expect(c.headers['X-Platform-Admin'], 'true');
    }
  });

  group('B2 Set up notifications (copy model)', () {
    const cmmVersions = [
      {'template_id': 'msg', 'version': 1, 'channel': 'IN_APP', 'locale': 'en', 'status': 'PUBLISHED', 'template': {'code': 'cmm_message', 'name': 'CMM message'}},
      {'template_id': 'msg', 'version': 3, 'channel': 'IN_APP', 'locale': 'en', 'status': 'PUBLISHED', 'template': {'code': 'cmm_message', 'name': 'CMM message'}},
      {'template_id': 'due', 'version': 1, 'channel': 'IN_APP', 'locale': 'en', 'status': 'PUBLISHED', 'template': {'code': 'cmm_upkeep_task_due', 'name': 'Upkeep due'}},
      {'template_id': 'due', 'version': 2, 'channel': 'IN_APP', 'locale': 'en', 'status': 'PUBLISHED', 'template': {'code': 'cmm_upkeep_task_due', 'name': 'Upkeep due'}},
      {'template_id': 'due', 'version': 4, 'channel': 'IN_APP', 'locale': 'en', 'status': 'DRAFT', 'template': {'code': 'cmm_upkeep_task_due', 'name': 'Upkeep due'}},
      {'template_id': 'due', 'version': 5, 'channel': 'SMS', 'locale': 'en', 'status': 'PUBLISHED', 'template': {'code': 'cmm_upkeep_task_due', 'name': 'Upkeep due'}},
    ];
    Map<String, dynamic Function(dynamic)> routes({List<Map<String, dynamic>> rules = const [], List<Map<String, dynamic>> tpls = cmmVersions}) => {
          'GET /v1/admin/rules': (_) => rules,
          'GET /v1/admin/rule-channels': (_) => [],
          'GET /v1/admin/events': (_) => [
                {'code': 'UPKEEP_TASK_DUE', 'version': 1},
                {'code': 'VISITOR_BLOCKED', 'version': 1},
                {'code': 'VISITOR_BLOCKED', 'version': 2},
                {'code': 'VISITOR_OVERSTAY', 'version': 1},
              ],
          'GET /v1/admin/templates': (_) => tpls,
          'GET /v1/admin/channels': (_) => [{'channel': 'IN_APP', 'enabled': true}],
        };
    NotificationApi cmmOrg(FakeEngine f) => platformFor(f).organization('cmm', 'soc1');

    testWidgets('creates one active rule per event on its own template at the latest version', (t) async {
      await big(t);
      var n = 0;
      final f = FakeEngine({
        ...routes(rules: [{'id': 'old', 'event_code': 'VISITOR_OVERSTAY', 'active': true}]),
        'POST /v1/admin/rules': (_) => {'id': 'r${++n}'},
        'POST /v1/admin/rule-channels': (_) => {'ok': true},
      });
      await t.pumpWidget(host(RulesTab(org: cmmOrg(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rule-setup')));
      await t.pumpAndSettle();
      expect(find.text('UPKEEP_TASK_DUE → Upkeep due v2'), findsOneWidget);
      expect(find.text('VISITOR_BLOCKED → CMM message v3'), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('VISITOR_OVERSTAY')), findsNothing);
      await tapText(t, 'Set up');
      expect(f.bodies('POST /v1/admin/rules'), [
        {'event_code': 'UPKEEP_TASK_DUE', 'event_version': 1, 'recipient_strategy': 'RECIPIENTS', 'purpose': 'upkeep_task_due', 'active': true},
        {'event_code': 'VISITOR_BLOCKED', 'event_version': 2, 'recipient_strategy': 'RECIPIENTS', 'purpose': 'visitor_blocked', 'active': true},
      ]);
      expect(f.bodies('POST /v1/admin/rule-channels'), [
        {'rule_id': 'r1', 'channel': 'IN_APP', 'template_id': 'due', 'template_version': 2},
        {'rule_id': 'r2', 'channel': 'IN_APP', 'template_id': 'msg', 'template_version': 3},
      ]);
      expect(find.text('2 rules created, 1 events already had one'), findsOneWidget);
      for (final c in f.calls) {
        expect(c.headers['X-Organization-Id'], 'soc1');
        expect(c.headers['X-Product-Code'], 'cmm');
      }
    });

    testWidgets('recipients can be everyone in the organization', (t) async {
      await big(t);
      final f = FakeEngine({...routes(), 'POST /v1/admin/rules': (_) => {'id': 'r'}, 'POST /v1/admin/rule-channels': (_) => {}});
      await t.pumpWidget(host(RulesTab(org: cmmOrg(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rule-setup')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('setup-strategy')));
      await t.pumpAndSettle();
      await t.tap(find.text('Everyone in the organization').last);
      await t.pumpAndSettle();
      await tapText(t, 'Set up');
      expect(f.bodies('POST /v1/admin/rules').map((b) => b['recipient_strategy']).toSet(), {'ALL_ORG_USERS'});
    });

    testWidgets('no button when every event already has an active rule, or no template is published', (t) async {
      await big(t);
      final all = [for (final e in ['UPKEEP_TASK_DUE', 'VISITOR_BLOCKED', 'VISITOR_OVERSTAY']) {'id': e, 'event_code': e, 'active': true}];
      await t.pumpWidget(host(RulesTab(org: cmmOrg(FakeEngine(routes(rules: all))))));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rule-setup')), findsNothing);
      await t.pumpWidget(host(RulesTab(key: const ValueKey('b'), org: cmmOrg(FakeEngine(routes(tpls: const []))))));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rule-setup')), findsNothing);
    });

    test('events without any template are reported, the rest still set up; failures are collected', () async {
      final f = FakeEngine({
        ...routes(tpls: [cmmVersions[2]]),
        'POST /v1/admin/rules': (_) => {'id': 'r1'},
        'POST /v1/admin/rule-channels': (_) => err(409, 'conflict', 'Template not available'),
      });
      final r = await setUpNotifications(cmmOrg(f));
      expect(r.created, 0);
      expect(r.failed, ['UPKEEP_TASK_DUE: Template not available', 'VISITOR_BLOCKED: no published template', 'VISITOR_OVERSTAY: no published template']);
    });
  });

  group('B2 Rules', () {
    testWidgets('creates a rule for a role, off by default', (t) async {
      await big(t);
      final f = FakeEngine({...rulesRoutes(rules: []), 'POST /v1/admin/rules': (_) => {'id': 'r2'}});
      await t.pumpWidget(host(RulesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(find.text('No rules yet'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rule-new')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('rule-role')), 'TENANT, OWNER ,');
      await tapText(t, 'Create');
      expect(f.bodies('POST /v1/admin/rules').single, {
        'event_code': 'RENT_DUE',
        'recipient_strategy': 'ALL_USERS_IN_ROLE',
        'role_codes': ['TENANT', 'OWNER'],
        'purpose': 'TRANSACTIONAL',
        'active': false,
      });
    });

    testWidgets('creating for everyone in the organization hides the role field', (t) async {
      await big(t);
      final f = FakeEngine({...rulesRoutes(rules: []), 'POST /v1/admin/rules': (_) => {'id': 'r2'}});
      await t.pumpWidget(host(RulesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rule-new')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rule-strategy')));
      await t.pumpAndSettle();
      await t.tap(find.text('Everyone in the organization').last);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rule-role')), findsNothing);
      await tapText(t, 'Create');
      final b = f.bodies('POST /v1/admin/rules').single;
      expect(b['recipient_strategy'], 'ALL_ORG_USERS');
      expect(b.containsKey('role_code'), isFalse);
      expect(b.containsKey('role_codes'), isFalse);
    });

    testWidgets('cannot turn a rule on without a channel', (t) async {
      await big(t);
      final f = FakeEngine({...rulesRoutes()});
      await t.pumpWidget(host(RulesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rule-active-r1')));
      await t.pumpAndSettle();
      expect(find.text('Add a channel before turning the rule on'), findsOneWidget);
      expect(f.hits('PUT /v1/admin/rules/r1'), isEmpty);
    });

    testWidgets('turns a rule with a channel on', (t) async {
      await big(t);
      final f = FakeEngine({
        ...rulesRoutes(bindings: [{'rule_id': 'r1', 'channel': 'IN_APP', 'template_id': 't1', 'template_version': 2}]),
        'PUT /v1/admin/rules/r1': (_) => {},
      });
      await t.pumpWidget(host(RulesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(find.text('In-app · Rent due v2'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rule-active-r1')));
      await t.pumpAndSettle();
      expect(f.bodies('PUT /v1/admin/rules/r1').single, {'active': true});
    });

    testWidgets('deletes a rule after confirming', (t) async {
      await big(t);
      final f = FakeEngine({...rulesRoutes(), 'DELETE /v1/admin/rules/r1': (_) => {}});
      await t.pumpWidget(host(RulesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rule-delete-r1')));
      await t.pumpAndSettle();
      await tapText(t, 'Cancel');
      expect(f.hits('DELETE /v1/admin/rules/r1'), isEmpty);
      await t.tap(find.byKey(const ValueKey('rule-delete-r1')));
      await t.pumpAndSettle();
      await tapText(t, 'Delete');
      expect(f.hits('DELETE /v1/admin/rules/r1'), hasLength(1));
    });

    testWidgets('adds a channel with the latest published template; only enabled channels are offered', (t) async {
      await big(t);
      final f = FakeEngine({...rulesRoutes(), 'POST /v1/admin/rule-channels': (_) => {}});
      await t.pumpWidget(host(RulesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('bind-r1')));
      await t.pumpAndSettle();
      expect(find.text('Rent due v2'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('bind-channel')));
      await t.pumpAndSettle();
      expect(find.text('Push'), findsNothing);
      await t.tap(find.text('SMS').last);
      await t.pumpAndSettle();
      expect(find.text('Rent due v1'), findsOneWidget);
      await tapText(t, 'Add');
      expect(f.bodies('POST /v1/admin/rule-channels').single, {'rule_id': 'r1', 'channel': 'SMS', 'template_id': 't1'});
    });

    testWidgets('removes a channel from a rule', (t) async {
      await big(t);
      final f = FakeEngine({
        ...rulesRoutes(bindings: [{'rule_id': 'r1', 'channel': 'SMS', 'template_id': 't1', 'template_version': 1}]),
        'DELETE /v1/admin/rule-channels/r1/SMS': (_) => {},
      });
      await t.pumpWidget(host(RulesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.descendant(of: find.byKey(const ValueKey('binding-r1-SMS')), matching: find.byTooltip('Delete')));
      await t.pumpAndSettle();
      expect(f.hits('DELETE /v1/admin/rule-channels/r1/SMS'), hasLength(1));
    });
  });

  group('B3 Templates', () {
    final bindings = [{'rule_id': 'r1', 'channel': 'IN_APP', 'template_id': 't1', 'template_version': 1}];

    testWidgets('shows the pinned version, a newer one, and upgrades with overrides carried', (t) async {
      await big(t);
      final f = FakeEngine({
        ...rulesRoutes(bindings: bindings),
        'GET /v1/admin/overrides': (_) => [{'id': 'ov1', 'template_id': 't1', 'channel': 'IN_APP', 'status': 'PUBLISHED', 'version': 1}],
        'POST /v1/admin/templates/t1/upgrade': (_) => {'upgraded': 1, 'skipped': 0, 'overridesCarried': 1},
      });
      await t.pumpWidget(host(OrgTemplatesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(find.text('v1 (v2 available)  '), findsOneWidget);
      expect(find.text('Override on In-app'), findsOneWidget);
      expect(find.text('Edit override'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tpl-upgrade-t1')));
      await t.pumpAndSettle();
      await tapText(t, 'Upgrade');
      expect(f.bodies('POST /v1/admin/templates/t1/upgrade').single, {'version': 2});
      expect(find.text('Upgraded 1 rule channel(s), 1 override(s) carried'), findsOneWidget);
    });

    testWidgets('no upgrade button when on the latest version; override opens the designer', (t) async {
      await big(t);
      final f = FakeEngine({
        ...rulesRoutes(bindings: [{'rule_id': 'r1', 'channel': 'IN_APP', 'template_id': 't1', 'template_version': 2}]),
        'GET /v1/admin/overrides': (_) => [],
        'GET /v1/admin/templates/t1/effective': (_) => {
              'master': {'content': {'title': 'Rent due', 'body': 'Pay {{data.amount}}'}},
              'override': null,
              'effective': {'title': 'Rent due', 'body': 'Pay {{data.amount}}'},
            },
        'GET /v1/admin/events/RENT_DUE/variables': (_) => {'variables': [{'path': 'data.amount'}]},
      });
      await t.pumpWidget(host(OrgTemplatesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tpl-upgrade-t1')), findsNothing);
      await t.tap(find.byKey(const ValueKey('tpl-override-t1')));
      await t.pumpAndSettle();
      expect(find.byType(TemplateDesigner), findsOneWidget);
      expect(find.byKey(const ValueKey('var-data.amount')), findsOneWidget);
      expect(find.text('Reset to platform'), findsNothing);
    });

    testWidgets('empty state when no rule uses a template', (t) async {
      await big(t);
      final f = FakeEngine({...rulesRoutes(), 'GET /v1/admin/overrides': (_) => []});
      await t.pumpWidget(host(OrgTemplatesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(find.text('No rule uses a template yet'), findsOneWidget);
    });
  });

  group('B7 Override designer', () {
    Map<String, dynamic Function(dynamic)> routes(Map<String, dynamic>? override) => {
          'GET /v1/admin/templates/t1/effective': (_) => {
                'master': {'content': {'title': 'Rent due', 'body': 'Pay now'}},
                'override': override,
                'effective': {'title': 'Rent due', 'body': override == null ? 'Pay now' : 'Pay by Friday'},
              },
          'POST /v1/admin/overrides': (_) => {'id': 'ov2'},
          'DELETE /v1/admin/overrides/ov1': (_) => {},
        };

    testWidgets('publishes only the changed fields; nothing changed is refused', (t) async {
      await big(t);
      final f = FakeEngine(routes(null));
      await t.pumpWidget(host(TemplateDesigner.override(api: orgFor(f), template: const {'id': 't1'}, baseVersion: 2)));
      await t.pumpAndSettle();
      await tapText(t, 'Publish override');
      expect(find.text('Nothing changed from the platform template'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('field-body')), 'Pay by Friday');
      await tapText(t, 'Publish override');
      expect(f.bodies('POST /v1/admin/overrides').single,
          {'template_id': 't1', 'base_version': 2, 'channel': 'IN_APP', 'locale': 'en', 'patch': {'body': 'Pay by Friday'}});
    });

    testWidgets('reset to platform removes the override', (t) async {
      await big(t);
      final f = FakeEngine(routes({'id': 'ov1', 'version': 3}));
      await t.pumpWidget(host(TemplateDesigner.override(api: orgFor(f), template: const {'id': 't1'}, baseVersion: 2)));
      await t.pumpAndSettle();
      expect(find.text('Override v3 published'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('field-body'))).controller!.text, 'Pay by Friday');
      await tapText(t, 'Reset to platform');
      await tapText(t, 'Reset');
      expect(f.hits('DELETE /v1/admin/overrides/ov1'), hasLength(1));
    });
  });

  group('B4 Channels', () {
    Map<String, dynamic Function(dynamic)> routes({required bool managed}) => {
          'GET /v1/admin/channels': (_) => [
                {'channel': 'IN_APP', 'enabled': true},
                {'channel': 'SMS', 'enabled': true},
              ],
          'GET /v1/admin/org-settings': (_) => {'managed': managed, 'settings': {}},
          'POST /v1/admin/channels': (_) => {},
          'POST /v1/admin/channels/SMS/test': (_) => {'outcome': 'SENT'},
        };

    testWidgets('managed org: provisioned channels are locked on, others can be added', (t) async {
      await big(t);
      final f = FakeEngine(routes(managed: true));
      await t.pumpWidget(host(OrgChannelsTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(t.widget<Switch>(find.byKey(const ValueKey('org-channel-switch-SMS'))).onChanged, isNull);
      expect(t.widget<Switch>(find.byKey(const ValueKey('org-channel-switch-PUSH'))).value, isFalse);
      await t.tap(find.byKey(const ValueKey('org-channel-switch-PUSH')));
      await t.pumpAndSettle();
      expect(f.bodies('POST /v1/admin/channels').single, {'channel': 'PUSH', 'enabled': true});
    });

    testWidgets('unmanaged org: a channel can be turned off', (t) async {
      await big(t);
      final f = FakeEngine(routes(managed: false));
      await t.pumpWidget(host(OrgChannelsTab(org: orgFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('org-channel-switch-SMS')));
      await t.pumpAndSettle();
      expect(f.bodies('POST /v1/admin/channels').single, {'channel': 'SMS', 'enabled': false});
    });

    testWidgets('sends a test to a phone number', (t) async {
      await big(t);
      final f = FakeEngine(routes(managed: true));
      await t.pumpWidget(host(OrgChannelsTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('org-channel-test-IN_APP')), findsNothing);
      await t.tap(find.byKey(const ValueKey('org-channel-test-SMS')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('org-test-target')), '+919800000000');
      await tapText(t, 'Send');
      expect(f.bodies('POST /v1/admin/channels/SMS/test').single, {'phone': '+919800000000'});
      expect(find.text('Test sent'), findsOneWidget);
    });
  });

  group('Preferences and member app (C1-C3)', () {
    Map<String, dynamic> settings({bool badge = true, bool members = false, String prompt = 'after_first_notification', int days = 90}) => {
          'managed': true,
          'settings': {
            'inbox_retention_days': days,
            'unread_badge': badge,
            'group_by_day': false,
            'push_prompt': prompt,
            'push_explanation': 'Gate alerts',
            'members_can_change': members,
          }
        };
    Map<String, dynamic Function(dynamic)> routes(Map<String, dynamic> s) => {
          'GET /v1/admin/org-preferences': (_) => {
                'groups': [
                  {'group': 'PAYMENTS', 'channels': [{'channel': 'IN_APP', 'source': 'PROVISIONED'}]},
                  {'group': 'VISITORS', 'channels': [{'channel': 'IN_APP', 'source': 'PROVISIONED'}, {'channel': 'SMS', 'source': 'ADDED'}]},
                ],
                'enabledChannels': ['IN_APP', 'SMS'],
              },
          'GET /v1/admin/org-settings': (_) => s,
          'POST /v1/admin/org-preferences': (_) => {},
          'PUT /v1/admin/org-settings': (_) => s,
        };

    testWidgets('existing channels are locked; only enabled channels can be added; add confirms', (t) async {
      await big(t);
      final f = FakeEngine(routes(settings()));
      await t.pumpWidget(host(OrgPreferencesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pref-locked-VISITORS-SMS')), findsOneWidget);
      expect(find.byKey(const ValueKey('pref-PAYMENTS-PUSH')), findsNothing); // PUSH not enabled for the org
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('prefs-add'))).onPressed, isNull);
      await t.tap(find.byKey(const ValueKey('pref-PAYMENTS-SMS')));
      await t.pump();
      expect(find.text('Add 1'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('prefs-add')));
      await t.pumpAndSettle();
      expect(find.text('Added channels cannot be removed later.'), findsOneWidget);
      await tapText(t, 'Add');
      expect(f.bodies('POST /v1/admin/org-preferences').single, {
        'items': [{'group': 'PAYMENTS', 'channel': 'SMS'}]
      });
    });

    testWidgets('settings: provisioned values cannot be lowered in the form', (t) async {
      await big(t);
      final f = FakeEngine(routes(settings()));
      await t.pumpWidget(host(OrgPreferencesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(t.widget<SwitchListTile>(find.byKey(const ValueKey('set-badge'))).onChanged, isNull);
      expect(t.widget<SwitchListTile>(find.byKey(const ValueKey('set-group-day'))).onChanged, isNotNull);
      await t.tap(find.byKey(const ValueKey('set-retention')));
      await t.pumpAndSettle();
      final thirty = t.widget<DropdownMenuItem<int>>(find.ancestor(of: find.text('30 days').last, matching: find.byType(DropdownMenuItem<int>)));
      expect(thirty.enabled, isFalse);
      await t.tap(find.text('365 days').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('set-push-prompt')));
      await t.pumpAndSettle();
      final never = t.widget<DropdownMenuItem<String>>(find.ancestor(of: find.text('Never ask').last, matching: find.byType(DropdownMenuItem<String>)));
      expect(never.enabled, isFalse);
      await t.tap(find.text('At first login').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('set-group-day')));
      await t.tap(find.byKey(const ValueKey('set-members-change')));
      await t.enterText(find.byKey(const ValueKey('set-push-explanation')), 'Know who is at the gate');
      await t.pump();
      await t.ensureVisible(find.byKey(const ValueKey('set-save')));
      await tapText(t, 'Save member app settings');
      expect(f.bodies('PUT /v1/admin/org-settings').single, {
        'inbox_retention_days': 365,
        'group_by_day': true,
        'push_prompt': 'first_login',
        'push_explanation': 'Know who is at the gate',
        'members_can_change': true,
      });
    });

    testWidgets('settings: saving with no change sends nothing; engine refusal is shown', (t) async {
      await big(t);
      final f = FakeEngine({
        ...routes(settings()),
        'PUT /v1/admin/org-settings': (_) => err(403, 'forbidden', 'organization settings are add-only'),
      });
      await t.pumpWidget(host(OrgPreferencesTab(org: orgFor(f))));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('set-save')));
      await tapText(t, 'Save member app settings');
      expect(find.text('Nothing changed'), findsOneWidget);
      expect(f.hits('PUT /v1/admin/org-settings'), isEmpty);
      await t.tap(find.byKey(const ValueKey('set-group-day')));
      await t.pump();
      await tapText(t, 'Save member app settings');
      expect(find.text('organization settings are add-only'), findsOneWidget);
    });
  });

  group('B5 Delivery log', () {
    final rows = [
      {'id': 'd1', 'channel': 'SMS', 'status': 'FAILED', 'attempts': 3, 'notification': {'title': 'Rent due', 'user_id': 'u1'}},
      {'id': 'd2', 'channel': 'IN_APP', 'status': 'DELIVERED', 'attempts': 1, 'notification': {'title': 'Visitor', 'user_id': 'u2'}},
    ];

    testWidgets('retry only on failed deliveries', (t) async {
      await big(t);
      final f = FakeEngine({'GET /v1/admin/deliveries': (_) => rows, 'POST /v1/admin/deliveries/d1/retry': (_) => {}});
      await t.pumpWidget(host(DeliveryLogTab(org: orgFor(f))));
      await t.pumpAndSettle();
      expect(find.text('To u1 · 3 attempt(s)'), findsOneWidget);
      expect(find.byKey(const ValueKey('delivery-retry-d2')), findsNothing);
      await t.tap(find.byKey(const ValueKey('delivery-retry-d1')));
      await t.pumpAndSettle();
      expect(f.hits('POST /v1/admin/deliveries/d1/retry'), hasLength(1));
      expect(find.text('Queued for retry'), findsOneWidget);
    });

    testWidgets('shows attempts with the provider error', (t) async {
      await big(t);
      final f = FakeEngine({
        'GET /v1/admin/deliveries': (_) => rows,
        'GET /v1/admin/deliveries/d1/attempts': (_) => [{'attempt': 1, 'outcome': 'RETRY', 'error': 'HTTP 500', 'created_at': 'now'}],
      });
      await t.pumpWidget(host(DeliveryLogTab(org: orgFor(f))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('delivery-attempts-d1')));
      await t.pumpAndSettle();
      expect(find.text('#1 RETRY · now'), findsOneWidget);
      expect(find.text('HTTP 500'), findsOneWidget);
    });
  });

  testWidgets('B6 audit lists changes newest first', (t) async {
    await big(t);
    final f = FakeEngine({'GET /v1/admin/audit': (_) => [{'id': 1, 'action': 'org_preferences.add', 'actor': 'platform:admin', 'created_at': 'now'}]});
    await t.pumpWidget(host(OrgAuditTab(org: orgFor(f))));
    await t.pumpAndSettle();
    expect(find.text('org_preferences.add'), findsOneWidget);
    expect(find.text('platform:admin · now'), findsOneWidget);
  });
}
