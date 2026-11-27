// Widget tests for the Notifications tab: one card per event with recipients, channels and wording.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notification_admin/notification_admin.dart';
import 'package:notification_sdk/notification_sdk.dart';

import 'fake.dart';

NotificationApi cmmOrg(FakeEngine f) => platformFor(f).organization('cmm', 'soc1');

const tpls = [
  {'template_id': 'due', 'version': 1, 'channel': 'IN_APP', 'locale': 'en', 'status': 'PUBLISHED', 'template': {'code': 'cmm_upkeep_task_due', 'name': 'CMM: Upkeep due'}},
  {'template_id': 'due', 'version': 2, 'channel': 'IN_APP', 'locale': 'en', 'status': 'PUBLISHED', 'template': {'code': 'cmm_upkeep_task_due', 'name': 'CMM: Upkeep due'}},
  {'template_id': 'due', 'version': 1, 'channel': 'SMS', 'locale': 'en', 'status': 'PUBLISHED', 'template': {'code': 'cmm_upkeep_task_due', 'name': 'CMM: Upkeep due'}},
  {'template_id': 'msg', 'version': 1, 'channel': 'IN_APP', 'locale': 'en', 'status': 'PUBLISHED', 'template': {'code': 'cmm_message', 'name': 'CMM message'}},
];

Map<String, dynamic> dueRule({
  String strategy = 'RECIPIENTS',
  String? role,
  List<String>? roles,
  List<String>? attributes,
  List<String>? phones,
  bool active = true,
}) =>
    {
      if (attributes != null) 'attribute_codes': attributes,
      if (phones != null) 'custom_phones': phones,
      'id': 'r1',
      'event_code': 'UPKEEP_TASK_DUE',
      'event_version': 2,
      'recipient_strategy': strategy,
      'role_code': role ?? roles?.first,
      if (roles != null) 'role_codes': roles,
      'purpose': 'upkeep_task_due',
      'active': active,
    };

FakeEngine engine({
  List<Map<String, dynamic>>? rules,
  List<Map<String, dynamic>>? bindings,
  List<Map<String, dynamic>> overrides = const [],
  List<Map<String, dynamic>> channels = const [
    {'channel': 'IN_APP', 'enabled': true},
    {'channel': 'SMS', 'enabled': true},
    {'channel': 'WHATSAPP', 'enabled': false},
  ],
}) =>
    FakeEngine({
      'GET /v1/admin/rules': (_) => rules ?? [dueRule()],
      'GET /v1/admin/rule-channels': (_) => bindings ?? [{'rule_id': 'r1', 'channel': 'IN_APP', 'template_id': 'due', 'template_version': 1}],
      'GET /v1/admin/events': (_) => [
            {'code': 'UPKEEP_TASK_DUE', 'version': 1, 'module_code': 'UPKEEP'},
            {
              'code': 'UPKEEP_TASK_DUE',
              'version': 2,
              'module_code': 'UPKEEP',
              'metadata': {
                'recipientAttributes': [
                  {'code': 'record_creator', 'label': 'Task creator'},
                  {'code': 'task_starter', 'label': 'Task starter'},
                ],
              },
            },
            {'code': 'VISITOR_BLOCKED', 'version': 2, 'module_code': 'VISITORS'},
          ],
      'GET /v1/admin/templates': (_) => tpls,
      'GET /v1/admin/channels': (_) => channels,
      'GET /v1/admin/overrides': (_) => overrides,
      'GET /v1/admin/roles': (_) => [
            {'code': 'role-uuid-treasurer', 'name': 'Treasurer', 'active': true},
            {'code': 'role-uuid-admin', 'name': 'Organization Admin', 'active': true},
            {'code': 'cmm_notification_admin', 'name': 'CMM notifications', 'active': true, 'notification_admin': true},
            {'code': 'old', 'name': 'Old role', 'active': false},
          ],
      'PUT /v1/admin/rules/r1': (_) => dueRule(),
      'POST /v1/admin/rules': (_) => {'id': 'r9'},
      'POST /v1/admin/rule-channels': (_) => {},
      'PUT /v1/admin/rules/r9': (_) => {'id': 'r9'},
      'DELETE /v1/admin/rule-channels/r1/IN_APP': (_) => {},
      'DELETE /v1/admin/overrides/ov1': (_) => {},
      'POST /v1/admin/templates/due/upgrade': (_) => {'upgraded': 1},
    });

Future<FakeEngine> pumpTab(WidgetTester t, FakeEngine f) async {
  await big(t);
  await t.pumpWidget(host(EventsTab(org: cmmOrg(f), organizationName: 'Hittop', expandEvents: true)));
  await t.pumpAndSettle();
  return f;
}

void main() {
  test('eventLabel reads like a sentence', () {
    expect(eventLabel('UPKEEP_TASK_DUE'), 'Upkeep task due');
    expect(eventLabel(''), '');
  });

  testWidgets('one card per event; an event without a rule offers Set up', (t) async {
    await pumpTab(t, engine());
    expect(find.text('Upkeep task due'), findsOneWidget);
    expect(find.text('Visitor blocked'), findsOneWidget);
    expect(find.byKey(const ValueKey('event-setup-VISITOR_BLOCKED')), findsOneWidget);
    expect(find.byKey(const ValueKey('event-active-UPKEEP_TASK_DUE')), findsOneWidget);
    expect(find.text('Not set up'), findsOneWidget);
  });

  testWidgets('platform wording and organization wording sit side by side, the one in use is marked', (t) async {
    await pumpTab(t, engine());
    final platform = find.byKey(const ValueKey('platform-UPKEEP_TASK_DUE-IN_APP'));
    final org = find.byKey(const ValueKey('org-UPKEEP_TASK_DUE-IN_APP'));
    expect(find.descendant(of: platform, matching: find.text('CMM: Upkeep due · v1')), findsOneWidget);
    expect(find.descendant(of: platform, matching: find.text('In use')), findsOneWidget);
    expect(find.descendant(of: org, matching: find.text('Uses the platform wording')), findsOneWidget);
    expect(find.descendant(of: org, matching: find.text('Customise wording')), findsOneWidget);
    expect(find.byKey(const ValueKey('upgrade-UPKEEP_TASK_DUE-IN_APP')), findsOneWidget); // v2 published
    expect(find.text('Off for the whole organization. Turn it on in "Channels on/off" first.'), findsOneWidget); // WhatsApp
  });

  testWidgets('own wording shows as ORGANIZATION in use, and can go back to platform wording', (t) async {
    final f = await pumpTab(t, engine(overrides: [
      {'id': 'ov1', 'template_id': 'due', 'channel': 'IN_APP', 'status': 'PUBLISHED', 'version': 3},
    ]));
    final org = find.byKey(const ValueKey('org-UPKEEP_TASK_DUE-IN_APP'));
    expect(find.descendant(of: org, matching: find.text('Own wording (override v3)')), findsOneWidget);
    expect(find.descendant(of: org, matching: find.text('In use')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('reset-UPKEEP_TASK_DUE-IN_APP')));
    await t.pumpAndSettle();
    await tapText(t, 'Reset');
    expect(f.hits('DELETE /v1/admin/overrides/ov1'), hasLength(1));
  });

  testWidgets('recipients: choosing "Everyone with a role" starts with the first product role by name', (t) async {
    final f = await pumpTab(t, engine());
    await t.tap(find.byKey(const ValueKey('who-r1')));
    await t.pumpAndSettle();
    await t.tap(find.text('Everyone with a role').last);
    await t.pumpAndSettle();
    // First selectable role by name (Organization Admin), not the system or inactive role.
    expect(f.bodies('PUT /v1/admin/rules/r1').single, {
      'recipient_strategy': 'ALL_USERS_IN_ROLE',
      'role_codes': ['role-uuid-admin'],
    });
  });

  testWidgets('several roles can be ticked; only active product roles are offered', (t) async {
    final f = await pumpTab(t, engine(rules: [dueRule(strategy: 'ALL_USERS_IN_ROLE', role: 'role-uuid-admin')]));
    expect(find.text('Roles (members of any of them)'), findsOneWidget);
    expect(find.byKey(const ValueKey('role-r1-cmm_notification_admin')), findsNothing);
    expect(find.byKey(const ValueKey('role-r1-old')), findsNothing);
    expect(t.widget<FilterChip>(find.byKey(const ValueKey('role-r1-role-uuid-admin'))).selected, isTrue);
    await t.tap(find.byKey(const ValueKey('role-r1-role-uuid-treasurer')));
    await t.pumpAndSettle();
    expect(f.bodies('PUT /v1/admin/rules/r1').single, {
      'role_codes': ['role-uuid-admin', 'role-uuid-treasurer'],
    });
  });

  testWidgets('a rule with several roles shows them all, and unticking one keeps the rest', (t) async {
    await big(t);
    final f = engine(rules: [dueRule(strategy: 'ALL_USERS_IN_ROLE', roles: ['role-uuid-treasurer', 'role-uuid-admin'])]);
    await t.pumpWidget(host(EventsTab(org: cmmOrg(f), organizationName: 'Hittop')));
    await t.pumpAndSettle();
    final summary = find.byKey(const ValueKey('event-summary-UPKEEP_TASK_DUE'));
    expect(find.descendant(of: summary, matching: find.text('Treasurer, Organization Admin')), findsOneWidget);
    await t.tap(find.text('Upkeep task due'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('role-r1-role-uuid-treasurer')));
    await t.pumpAndSettle();
    expect(f.bodies('PUT /v1/admin/rules/r1').single, {'role_codes': ['role-uuid-admin']});
  });

  testWidgets('the last role cannot be unticked', (t) async {
    final f = await pumpTab(t, engine(rules: [dueRule(strategy: 'ALL_USERS_IN_ROLE', role: 'role-uuid-admin')]));
    await t.tap(find.byKey(const ValueKey('role-r1-role-uuid-admin')));
    await t.pumpAndSettle();
    expect(f.hits('PUT /v1/admin/rules/r1'), isEmpty);
    expect(find.textContaining('Keep at least one role'), findsOneWidget);
  });

  test('typed numbers become E.164 like the engine does', () {
    expect(normalizePhone('98765 43210'), '+919876543210');
    expect(normalizePhone('098765-43210'), '+919876543210');
    expect(normalizePhone('91 9876543210'), '+919876543210');
    expect(normalizePhone('+1 (415) 555-0100'), '+14155550100');
    expect(normalizePhone('12345'), isNull);
    expect(normalizePhone('5876543210'), isNull);
  });

  testWidgets('also notify: people linked to the record are offered per event and saved', (t) async {
    final f = await pumpTab(t, engine());
    expect(find.text('Also notify'), findsOneWidget);
    expect(find.byKey(const ValueKey('attr-r1-record_creator')), findsOneWidget);
    expect(find.byKey(const ValueKey('attr-r1-task_starter')), findsOneWidget);
    expect(find.byKey(const ValueKey('attr-r1-flat_owner')), findsNothing);
    await t.tap(find.byKey(const ValueKey('attr-r1-record_creator')));
    await t.pumpAndSettle();
    expect(f.bodies('PUT /v1/admin/rules/r1').single, {'attribute_codes': ['record_creator']});
  });

  testWidgets('also notify: unticking a person keeps the others', (t) async {
    final f = await pumpTab(t, engine(rules: [dueRule(attributes: ['record_creator', 'task_starter'])]));
    expect(t.widget<FilterChip>(find.byKey(const ValueKey('attr-r1-task_starter'))).selected, isTrue);
    await t.tap(find.byKey(const ValueKey('attr-r1-task_starter')));
    await t.pumpAndSettle();
    expect(f.bodies('PUT /v1/admin/rules/r1').single, {'attribute_codes': ['record_creator']});
  });

  testWidgets('also notify: a typed number is added as E.164; a bad one is refused', (t) async {
    final f = await pumpTab(t, engine());
    await t.enterText(find.byKey(const ValueKey('phone-input-r1')), '12345');
    await t.tap(find.byKey(const ValueKey('phone-add-r1')));
    await t.pumpAndSettle();
    expect(f.hits('PUT /v1/admin/rules/r1'), isEmpty);
    expect(find.textContaining('Enter a phone number'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('phone-input-r1')), '98765 43210');
    await t.tap(find.byKey(const ValueKey('phone-add-r1')));
    await t.pumpAndSettle();
    expect(f.bodies('PUT /v1/admin/rules/r1').single, {'custom_phones': ['+919876543210']});
  });

  testWidgets('also notify: a listed number can be removed, and a duplicate is not added twice', (t) async {
    final f = await pumpTab(t, engine(rules: [dueRule(phones: ['+919876543210', '+14155550100'])]));
    expect(find.byKey(const ValueKey('phone-r1-+919876543210')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('phone-input-r1')), '9876543210');
    await t.tap(find.byKey(const ValueKey('phone-add-r1')));
    await t.pumpAndSettle();
    expect(f.hits('PUT /v1/admin/rules/r1'), isEmpty);
    expect(find.textContaining('already on the list'), findsOneWidget);
    await t.tap(find.byTooltip('Remove +919876543210'));
    await t.pumpAndSettle();
    expect(f.bodies('PUT /v1/admin/rules/r1').single, {'custom_phones': ['+14155550100']});
  });

  testWidgets('"Only the people chosen below" turns the product recipients off', (t) async {
    final f = await pumpTab(t, engine());
    await t.tap(find.byKey(const ValueKey('who-r1')));
    await t.pumpAndSettle();
    await t.tap(find.text('Only the people chosen below').last);
    await t.pumpAndSettle();
    expect(f.bodies('PUT /v1/admin/rules/r1').single, {'recipient_strategy': 'NONE'});
  });

  testWidgets('the card summary lists the extra people and numbers', (t) async {
    await big(t);
    final f = engine(rules: [dueRule(attributes: ['record_creator'], phones: ['+919876543210'])]);
    await t.pumpWidget(host(EventsTab(org: cmmOrg(f), organizationName: 'Hittop')));
    await t.pumpAndSettle();
    final summary = find.byKey(const ValueKey('event-summary-UPKEEP_TASK_DUE'));
    expect(find.descendant(of: summary, matching: find.text('Decided by CMM + Task creator + 1 number')), findsOneWidget);
  });

  testWidgets('a removed role is flagged on the rule', (t) async {
    await pumpTab(t, engine(rules: [dueRule(strategy: 'ALL_USERS_IN_ROLE', roles: ['role-uuid-admin', 'gone'])]));
    expect(find.text('No longer a role here: gone'), findsOneWidget);
  });

  testWidgets('Decided by the product explains that the product picks the people', (t) async {
    await pumpTab(t, engine());
    expect(find.text('Decided by CMM (its notification roles)'), findsOneWidget);
    expect(find.text('CMM sends the people with each event, from its own role settings.'), findsOneWidget);
  });

  testWidgets('turning a channel on binds the event template at its latest version', (t) async {
    final f = await pumpTab(t, engine());
    await t.tap(find.byKey(const ValueKey('ch-on-UPKEEP_TASK_DUE-SMS')));
    await t.pumpAndSettle();
    expect(f.bodies('POST /v1/admin/rule-channels').single,
        {'rule_id': 'r1', 'channel': 'SMS', 'template_id': 'due', 'template_version': 1});
  });

  testWidgets('turning off the last channel asks, then turns the event off too', (t) async {
    final f = await pumpTab(t, engine());
    await t.tap(find.byKey(const ValueKey('ch-on-UPKEEP_TASK_DUE-IN_APP')));
    await t.pumpAndSettle();
    expect(find.text('Turn off the last channel?'), findsOneWidget);
    await tapText(t, 'Turn off');
    expect(f.bodies('PUT /v1/admin/rules/r1').single, {'active': false});
    expect(f.hits('DELETE /v1/admin/rule-channels/r1/IN_APP'), hasLength(1));
  });

  testWidgets('Set up creates the rule on the latest event version with in-app on, then turns it on', (t) async {
    final f = await pumpTab(t, engine());
    await t.tap(find.byKey(const ValueKey('event-setup-VISITOR_BLOCKED')));
    await t.pumpAndSettle();
    expect(f.bodies('POST /v1/admin/rules').single,
        {'event_code': 'VISITOR_BLOCKED', 'event_version': 2, 'recipient_strategy': 'RECIPIENTS', 'purpose': 'visitor_blocked', 'active': false});
    expect(f.bodies('POST /v1/admin/rule-channels').single, {'rule_id': 'r9', 'channel': 'IN_APP', 'template_id': 'msg', 'template_version': 1});
    expect(f.bodies('PUT /v1/admin/rules/r9').single, {'active': true});
  });

  testWidgets('upgrade asks first, then moves the template to the newer platform version', (t) async {
    final f = await pumpTab(t, engine());
    await t.tap(find.byKey(const ValueKey('upgrade-UPKEEP_TASK_DUE-IN_APP')));
    await t.pumpAndSettle();
    await tapText(t, 'Upgrade');
    expect(f.bodies('POST /v1/admin/templates/due/upgrade').single, {'version': 2});
  });

  testWidgets('wording editor opens with the platform wording read-only above the organization wording', (t) async {
    final f = engine();
    f.routes['GET /v1/admin/templates/due/effective'] = (_) => {
          'master': {'content': {'title': 'Upkeep due', 'body': 'Task {{data.reference}} is due {{data.due_date}}'}},
          'override': null,
          'effective': {'title': 'Upkeep due', 'body': 'Task {{data.reference}} is due {{data.due_date}}'},
        };
    f.routes['GET /v1/admin/events/UPKEEP_TASK_DUE/variables'] = (_) => {
          'variables': [
            {'path': 'data.reference', 'type': 'string', 'source': 'platform'},
            {'path': 'data.task_title', 'type': 'string', 'source': 'product'},
          ]
        };
    await pumpTab(t, f);
    await t.tap(find.byKey(const ValueKey('wording-UPKEEP_TASK_DUE-IN_APP')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('platform-wording')), findsOneWidget);
    expect(find.text('PLATFORM WORDING · v1 · read-only'), findsOneWidget);
    expect(find.text("THIS ORGANIZATION'S WORDING"), findsOneWidget);
    // Variables of the rule's event version (v2), so CMM's own fields are offered.
    expect(f.hits('GET /v1/admin/events/UPKEEP_TASK_DUE/variables').single.url.queryParameters['version'], '2');
    expect(find.byKey(const ValueKey('var-data.task_title')), findsOneWidget);
  });

  testWidgets('workspace opens on the Notifications tab', (t) async {
    await big(t);
    final f = engine();
    await t.pumpWidget(host(OrganizationWorkspace(api: platformFor(f), productCode: 'cmm', organizationId: 'soc1', organizationName: 'Hittop')));
    await t.pumpAndSettle();
    expect(OrganizationWorkspace.tabs.first, 'Notifications');
    expect(find.byKey(const ValueKey('event-UPKEEP_TASK_DUE')), findsOneWidget);
  });

  testWidgets('events are grouped by area; cards start collapsed with a one-line summary', (t) async {
    await big(t);
    final f = engine(overrides: [
      {'id': 'ov1', 'template_id': 'due', 'channel': 'IN_APP', 'status': 'PUBLISHED', 'version': 3},
    ], rules: [dueRule(strategy: 'ALL_USERS_IN_ROLE', role: 'role-uuid-treasurer')]);
    await t.pumpWidget(host(EventsTab(org: cmmOrg(f), organizationName: 'Hittop')));
    await t.pumpAndSettle();
    expect(find.text('Upkeep'), findsOneWidget);
    expect(find.text('Visitors'), findsOneWidget);
    expect(find.text('1 event · 1 on'), findsOneWidget);
    expect(find.text('1 event · 0 on'), findsOneWidget);
    final summary = find.byKey(const ValueKey('event-summary-UPKEEP_TASK_DUE'));
    expect(find.descendant(of: summary, matching: find.text('Treasurer')), findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('IN-APP')), findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('ORG WORDING')), findsOneWidget);
    // Collapsed: channel rows are not shown until the card is opened.
    expect(find.byKey(const ValueKey('platform-UPKEEP_TASK_DUE-IN_APP')).hitTestable(), findsNothing);
    await t.tap(find.text('Upkeep task due'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('platform-UPKEEP_TASK_DUE-IN_APP')).hitTestable(), findsOneWidget);
    // Collapsing a whole area hides its events.
    await t.tap(find.text('Visitors'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('event-setup-VISITOR_BLOCKED')).hitTestable(), findsNothing);
  });

  testWidgets('summary shows platform wording and the product deciding recipients by default', (t) async {
    await big(t);
    final f = engine();
    await t.pumpWidget(host(EventsTab(org: cmmOrg(f), organizationName: 'Hittop')));
    await t.pumpAndSettle();
    final summary = find.byKey(const ValueKey('event-summary-UPKEEP_TASK_DUE'));
    expect(find.descendant(of: summary, matching: find.text('Decided by CMM')), findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('PLATFORM WORDING')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('event-summary-VISITOR_BLOCKED')), matching: find.text('Not set up')), findsOneWidget);
  });
}
