import 'package:flutter/material.dart';
import 'package:notification_sdk/notification_sdk.dart';

import 'common.dart';
import 'designer.dart';
import 'platform_api.dart';

/// B: one organization's notification workspace, opened by the super admin from the organization list.
///
/// Tabs: Rules (B2), Templates (B3), Channels (B4), Preferences and member app settings (C1-C3, add-only),
/// Delivery log (B5) and Audit (B6). Every call goes through the platform principal with
/// X-Product-Code / X-Organization-Id set by [NotificationPlatformApi.organization].
class OrganizationWorkspace extends StatelessWidget {
  final NotificationPlatformApi? api;
  final NotificationApi org;
  final String productCode;
  final String organizationId;
  final String organizationName;

  OrganizationWorkspace({
    super.key,
    required NotificationPlatformApi this.api,
    required this.productCode,
    required this.organizationId,
    required this.organizationName,
  }) : org = api.organization(productCode, organizationId);

  /// For tests and hosts that already hold an organization-scoped client.
  const OrganizationWorkspace.withClient({
    super.key,
    required this.org,
    required this.productCode,
    required this.organizationId,
    required this.organizationName,
  }) : api = null;

  static const tabs = ['Rules', 'Templates', 'Channels', 'Preferences', 'Delivery log', 'Audit'];

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: tabs.length,
        child: Column(children: [
          TabBar(isScrollable: true, tabs: [for (final t in tabs) Tab(text: t)]),
          Expanded(
            child: TabBarView(children: [
              RulesTab(org: org),
              OrgTemplatesTab(org: org),
              OrgChannelsTab(org: org),
              OrgPreferencesTab(org: org),
              DeliveryLogTab(org: org),
              OrgAuditTab(org: org),
            ]),
          ),
        ]),
      );
}

// =========================================================================== B2 rules

class RulesData {
  final List<Json> rules, bindings, events, templates, channels;
  RulesData(this.rules, this.bindings, this.events, this.templates, this.channels);

  List<String> get enabledChannels =>
      channels.where((c) => c['enabled'] == true).map((c) => c['channel'] as String).toList();

  /// Published template versions for a channel, one entry per template (latest version).
  List<Json> templatesFor(String channel) {
    final byId = <String, Json>{};
    for (final v in templates.where((v) => v['channel'] == channel && v['status'] == 'PUBLISHED')) {
      final id = v['template_id'] as String;
      if (byId[id] == null || (v['version'] as int) > (byId[id]!['version'] as int)) byId[id] = v;
    }
    return byId.values.toList();
  }

  String templateName(String id) {
    final t = templates.firstWhere((v) => v['template_id'] == id, orElse: () => const {});
    final m = t['template'];
    return m is Map ? (m['name'] ?? m['code'] ?? id).toString() : id;
  }
}

/// Result of [setUpNotifications].
class SetupResult {
  int created = 0, skipped = 0;
  final failed = <String>[];
}

/// The template each event would get from [setUpNotifications]: `<product>_<event>` when it has a published
/// version on [channel]/[locale], otherwise `<product>_message`; always the latest published version.
/// Events that already have an active rule are left out. A null value means no template is available.
Map<String, Json?> setupPlan(RulesData d, String productCode, {String channel = 'IN_APP', String locale = 'en'}) {
  final latest = <String, Json>{};
  for (final v in d.templates) {
    if (v['channel'] != channel || v['status'] != 'PUBLISHED' || (v['locale'] ?? 'en') != locale) continue;
    final m = v['template'];
    final code = (m is Map ? m['code'] : null)?.toString().toLowerCase();
    if (code == null) continue;
    if (latest[code] == null || (v['version'] as int) > (latest[code]!['version'] as int)) latest[code] = v;
  }
  final pc = productCode.toLowerCase();
  final active = d.rules.where((r) => r['active'] == true).map((r) => r['event_code']).toSet();
  final events = d.events.map((e) => e['code'] as String).toSet().where((e) => !active.contains(e)).toList()..sort();
  return {for (final e in events) e: latest['${pc}_${e.toLowerCase()}'] ?? latest['${pc}_message']};
}

/// Sets an organization up the way a product does on its first setup: one active rule per event that has no
/// active rule yet, bound on [channel] to the event's template at the latest published version (see [setupPlan]).
/// After this the organization owns its copy: later platform versions reach it only through an upgrade.
Future<SetupResult> setUpNotifications(NotificationApi org,
    {String strategy = 'RECIPIENTS', String channel = 'IN_APP', String locale = 'en'}) async {
  final d = await loadRules(org);
  final r = SetupResult()..skipped = d.events.map((e) => e['code']).toSet().length;
  final versions = <String, int>{};
  for (final e in d.events) {
    final v = (e['version'] as num?)?.toInt() ?? 1;
    if (v > (versions[e['code'] as String] ?? 0)) versions[e['code'] as String] = v;
  }
  final plan = setupPlan(d, org.productCode ?? '', channel: channel, locale: locale);
  r.skipped -= plan.length;
  for (final MapEntry(key: event, value: tpl) in plan.entries) {
    if (tpl == null) {
      r.failed.add('$event: no published template');
      continue;
    }
    try {
      final rule = await org.createRule({
        'event_code': event,
        'event_version': versions[event] ?? 1,
        'recipient_strategy': strategy,
        'purpose': event.toLowerCase(),
        'active': true,
      });
      await org.bindChannel(rule['id'] as String, channel, tpl['template_id'] as String, version: tpl['version'] as int);
      r.created++;
    } catch (e) {
      r.failed.add('$event: ${errorText(e)}');
    }
  }
  return r;
}

Future<RulesData> loadRules(NotificationApi org) async {
  final r = await Future.wait([
    org.adminList('rules'),
    org.adminList('rule-channels'),
    org.adminList('events'),
    org.adminList('templates'),
    org.adminList('channels'),
  ]);
  return RulesData(r[0], r[1], r[2], r[3], r[4]);
}

class RulesTab extends StatelessWidget {
  final NotificationApi org;
  const RulesTab({super.key, required this.org});

  @override
  Widget build(BuildContext context) => Loaded<RulesData>(
        load: () => loadRules(org),
        builder: (context, d, reload) => ListView(children: [
          PageHeader('Rules',
              subtitle: 'Which event notifies whom, on which channels, with which template.',
              actions: [
                if (setupPlan(d, org.productCode ?? '').values.any((v) => v != null))
                  OutlinedButton.icon(
                      key: const ValueKey('rule-setup'),
                      onPressed: () => _setUp(context, d, reload),
                      icon: const Icon(Icons.auto_fix_high),
                      label: const Text('Set up notifications')),
                FilledButton.icon(
                    key: const ValueKey('rule-new'),
                    onPressed: () => _create(context, d, reload),
                    icon: const Icon(Icons.add),
                    label: const Text('New rule')),
              ]),
          if (d.rules.isEmpty) const ListTile(title: Text('No rules yet')),
          for (final r in d.rules) _RuleCard(org: org, rule: r, data: d, reload: reload),
        ]),
      );

  Future<void> _setUp(BuildContext context, RulesData d, Future<void> Function() reload) async {
    final plan = setupPlan(d, org.productCode ?? '');
    String strategy = 'RECIPIENTS';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Set up notifications'),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('One active in-app rule per event, on the latest published template. '
                  'After this the organization keeps its own copy; later versions reach it only when you roll them out.'),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: const ValueKey('setup-strategy'),
                initialValue: strategy,
                decoration: const InputDecoration(labelText: 'Recipients'),
                items: const [
                  DropdownMenuItem(value: 'RECIPIENTS', child: Text('Users listed in the event')),
                  DropdownMenuItem(value: 'ALL_ORG_USERS', child: Text('Everyone in the organization')),
                ],
                onChanged: (v) => set(() => strategy = v!),
              ),
              const SizedBox(height: 8),
              for (final MapEntry(key: e, value: tpl) in plan.entries)
                Text(tpl == null
                    ? '$e: no published template (skipped)'
                    : '$e → ${d.templateName(tpl['template_id'] as String)} v${tpl['version']}'),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Set up')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final r = await setUpNotifications(org, strategy: strategy);
    if (context.mounted) {
      toast(context,
          '${r.created} rules created${r.skipped > 0 ? ', ${r.skipped} events already had one' : ''}'
          '${r.failed.isEmpty ? '' : ', ${r.failed.length} failed (${r.failed.first})'}');
    }
    await reload();
  }

  Future<void> _create(BuildContext context, RulesData d, Future<void> Function() reload) async {
    final events = d.events.map((e) => e['code'] as String).toSet().toList()..sort();
    if (events.isEmpty) return toast(context, 'This product has no events yet');
    String event = events.first;
    String strategy = 'ALL_USERS_IN_ROLE';
    final role = TextEditingController(), purpose = TextEditingController(text: 'TRANSACTIONAL');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New rule'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              key: const ValueKey('rule-event'),
              initialValue: event,
              decoration: const InputDecoration(labelText: 'Event'),
              items: [for (final e in events) DropdownMenuItem(value: e, child: Text(e))],
              onChanged: (v) => set(() => event = v!),
            ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              key: const ValueKey('rule-strategy'),
              initialValue: strategy,
              decoration: const InputDecoration(labelText: 'Recipients'),
              items: const [
                DropdownMenuItem(value: 'ALL_USERS_IN_ROLE', child: Text('Everyone with a role')),
                DropdownMenuItem(value: 'ALL_ORG_USERS', child: Text('Everyone in the organization')),
                DropdownMenuItem(value: 'RECIPIENTS', child: Text('Users listed in the event')),
              ],
              onChanged: (v) => set(() => strategy = v!),
            ),
            if (strategy == 'ALL_USERS_IN_ROLE')
              TextField(key: const ValueKey('rule-role'), controller: role, decoration: const InputDecoration(labelText: 'Role code')),
            TextField(key: const ValueKey('rule-purpose'), controller: purpose, decoration: const InputDecoration(labelText: 'Purpose')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final created = await runAction(
        context,
        () => org.createRule({
              'event_code': event,
              'recipient_strategy': strategy,
              if (strategy == 'ALL_USERS_IN_ROLE' && role.text.trim().isNotEmpty) 'role_code': role.text.trim(),
              'purpose': purpose.text.trim(),
              'active': false,
            }),
        done: 'Rule created (off until you add a channel and turn it on)');
    if (created) await reload();
  }
}

class _RuleCard extends StatelessWidget {
  final NotificationApi org;
  final Json rule;
  final RulesData data;
  final Future<void> Function() reload;
  const _RuleCard({required this.org, required this.rule, required this.data, required this.reload});

  String get id => rule['id'] as String;

  @override
  Widget build(BuildContext context) {
    final bindings = data.bindings.where((b) => b['rule_id'] == id).toList();
    final who = rule['recipient_strategy'] == 'ALL_USERS_IN_ROLE' ? 'Role ${rule['role_code'] ?? '?'}' : rule['recipient_strategy'];
    return Card(
      key: ValueKey('rule-$id'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('${rule['event_code']}  →  $who', style: Theme.of(context).textTheme.titleMedium)),
            Switch(
              key: ValueKey('rule-active-$id'),
              value: rule['active'] == true,
              onChanged: (v) async {
                if (v && bindings.isEmpty) return toast(context, 'Add a channel before turning the rule on');
                if (await runAction(context, () => org.updateRule(id, {'active': v}), done: v ? 'Rule on' : 'Rule off')) await reload();
              },
            ),
            IconButton(
              key: ValueKey('rule-delete-$id'),
              tooltip: 'Delete rule',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await confirm(context, title: 'Delete rule?', message: 'Notifications for ${rule['event_code']} stop going to $who.', action: 'Delete')) return;
                if (context.mounted && await runAction(context, () => org.deleteRule(id), done: 'Rule deleted')) await reload();
              },
            ),
          ]),
          Text('Purpose ${rule['purpose']}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(children: [
            for (final b in bindings)
              Padding(
                padding: const EdgeInsets.only(right: 4, bottom: 4),
                child: InputChip(
                  key: ValueKey('binding-$id-${b['channel']}'),
                  label: Text('${chLabel(b['channel'] as String)} · ${data.templateName(b['template_id'] as String)} v${b['template_version']}'),
                  onDeleted: () async {
                    if (await runAction(context, () => org.unbindChannel(id, b['channel'] as String), done: 'Channel removed')) await reload();
                  },
                ),
              ),
            ActionChip(
              key: ValueKey('bind-$id'),
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('Channel'),
              onPressed: () => _bind(context, bindings.map((b) => b['channel'] as String).toSet()),
            ),
          ]),
        ]),
      ),
    );
  }

  Future<void> _bind(BuildContext context, Set<String> bound) async {
    final options = data.enabledChannels.where((c) => !bound.contains(c)).toList();
    if (options.isEmpty) return toast(context, 'Every enabled channel is already on this rule');
    String channel = options.first;
    String? templateId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final templates = data.templatesFor(channel);
        if (templateId != null && !templates.any((t) => t['template_id'] == templateId)) templateId = null;
        templateId ??= templates.isEmpty ? null : templates.first['template_id'] as String;
        return AlertDialog(
          title: const Text('Add channel'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              key: const ValueKey('bind-channel'),
              initialValue: channel,
              decoration: const InputDecoration(labelText: 'Channel'),
              items: [for (final c in options) DropdownMenuItem(value: c, child: Text(chLabel(c)))],
              onChanged: (v) => set(() => channel = v!),
            ),
            if (templates.isEmpty)
              const Padding(padding: EdgeInsets.only(top: 12), child: Text('No published template for this channel yet'))
            else
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey('bind-template-$channel'),
                initialValue: templateId,
                decoration: const InputDecoration(labelText: 'Template (latest published version)'),
                items: [
                  for (final t in templates)
                    DropdownMenuItem(value: t['template_id'] as String, child: Text('${data.templateName(t['template_id'] as String)} v${t['version']}'))
                ],
                onChanged: (v) => set(() => templateId = v),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: templateId == null ? null : () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        );
      }),
    );
    if (ok == true && context.mounted && await runAction(context, () => org.bindChannel(id, channel, templateId!), done: 'Channel added')) {
      await reload();
    }
  }
}

// =========================================================================== B3 templates

/// Templates this organization uses, the version it is pinned to, overrides, and upgrades.
class OrgTemplatesTab extends StatelessWidget {
  final NotificationApi org;
  const OrgTemplatesTab({super.key, required this.org});

  static Future<(RulesData, List<Json>)> _load(NotificationApi org) async {
    final r = await Future.wait([loadRules(org), org.adminList('overrides')]);
    return (r[0] as RulesData, r[1] as List<Json>);
  }

  @override
  Widget build(BuildContext context) => Loaded<(RulesData, List<Json>)>(
        load: () => _load(org),
        builder: (context, data, reload) {
          final (d, overrides) = data;
          final used = <String, Json>{};
          for (final b in d.bindings) {
            final t = b['template_id'] as String;
            final cur = used[t];
            used[t] = {
              'id': t,
              'pinned': cur == null ? b['template_version'] : [cur['pinned'] as int, b['template_version'] as int].reduce((a, c) => a < c ? a : c),
              'channels': {...(cur?['channels'] as Set? ?? <String>{}), b['channel']},
              'event': (d.rules.firstWhere((r) => r['id'] == b['rule_id'], orElse: () => const {}))['event_code'],
            };
          }
          return ListView(children: [
            const PageHeader('Templates',
                subtitle: 'The platform template version each rule uses, this organization\'s overrides, and upgrades to newer versions.'),
            if (used.isEmpty) const ListTile(title: Text('No rule uses a template yet')),
            for (final u in used.values) _templateCard(context, d, u, overrides, reload),
          ]);
        },
      );

  Widget _templateCard(BuildContext context, RulesData d, Json u, List<Json> overrides, Future<void> Function() reload) {
    final id = u['id'] as String;
    final pinned = u['pinned'] as int;
    final latest = d.templates
        .where((v) => v['template_id'] == id && v['status'] == 'PUBLISHED')
        .fold<int>(0, (m, v) => (v['version'] as int) > m ? v['version'] as int : m);
    final active = overrides.where((o) => o['template_id'] == id && o['status'] == 'PUBLISHED').toList();
    final channels = (u['channels'] as Set).cast<String>();
    return Card(
      key: ValueKey('tpl-$id'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        title: Text(d.templateName(id)),
        subtitle: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('v$pinned${latest > pinned ? ' (v$latest available)' : ''}  '),
          for (final c in channels) channelChip(c),
          if (active.isNotEmpty) statusChip('Override on ${active.map((o) => chLabel(o['channel'] as String)).join(', ')}', color: Colors.deepPurple),
        ]),
        trailing: Wrap(spacing: 4, children: [
          if (latest > pinned)
            OutlinedButton(
              key: ValueKey('tpl-upgrade-$id'),
              onPressed: () async {
                if (!await confirm(context,
                    title: 'Upgrade to v$latest?',
                    message: 'Rules using v$pinned move to v$latest. Overrides are carried over when the fields still exist.',
                    action: 'Upgrade')) {
                  return;
                }
                if (!context.mounted) return;
                Json? res;
                final ok = await runAction(context, () async => res = await org.upgradeTemplate(id, version: latest));
                if (ok && context.mounted) {
                  toast(context, 'Upgraded ${res?['upgraded'] ?? 0} rule channel(s), ${res?['overridesCarried'] ?? 0} override(s) carried');
                  await reload();
                }
              },
              child: const Text('Upgrade'),
            ),
          OutlinedButton(
            key: ValueKey('tpl-override-$id'),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => Scaffold(
                      appBar: AppBar(title: Text('Override · ${d.templateName(id)}')),
                      body: TemplateDesigner.override(
                          api: org,
                          template: {'id': id, 'name': d.templateName(id)},
                          baseVersion: pinned,
                          eventCode: u['event'] as String?,
                          initialChannel: channels.first))));
              await reload();
            },
            child: Text(active.isEmpty ? 'Override' : 'Edit override'),
          ),
        ]),
      ),
    );
  }
}

// =========================================================================== B4 channels

/// Channels on for this organization. Add-only: a provisioned channel cannot be turned off here.
/// Providers are platform level and shown read-only.
class OrgChannelsTab extends StatelessWidget {
  final NotificationApi org;
  const OrgChannelsTab({super.key, required this.org});

  static Future<(List<Json>, Json)> _load(NotificationApi org) async {
    final r = await Future.wait([org.adminList('channels'), org.orgSettings()]);
    return (r[0] as List<Json>, r[1] as Json);
  }

  @override
  Widget build(BuildContext context) => Loaded<(List<Json>, Json)>(
        load: () => _load(org),
        builder: (context, data, reload) {
          final (rows, settings) = data;
          final managed = settings['managed'] == true;
          final on = {for (final r in rows) r['channel'] as String: r['enabled'] == true};
          return ListView(children: [
            PageHeader('Channels',
                subtitle: managed
                    ? 'Channels were chosen when the organization was created. You can add channels; provisioned ones stay on.'
                    : 'Channels on for this organization. Providers are set up once for the platform under Channels.'),
            for (final c in kChannels)
              ListTile(
                key: ValueKey('org-channel-$c'),
                title: Text(chLabel(c)),
                subtitle: Text(c == 'IN_APP' ? 'Built in' : 'Platform provider'),
                trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                  if (on[c] == true && c != 'IN_APP')
                    TextButton(
                      key: ValueKey('org-channel-test-$c'),
                      onPressed: () => _test(context, c),
                      child: const Text('Send test'),
                    ),
                  Switch(
                    key: ValueKey('org-channel-switch-$c'),
                    value: on[c] == true,
                    onChanged: (on[c] == true && managed)
                        ? null
                        : (v) async {
                            if (await runAction(context, () => org.setChannelEnabled(c, v), done: v ? '${chLabel(c)} on' : '${chLabel(c)} off')) {
                              await reload();
                            }
                          },
                  ),
                ]),
              ),
          ]);
        },
      );

  Future<void> _test(BuildContext context, String channel) async {
    final target = TextEditingController();
    final phone = channel == 'SMS' || channel == 'WHATSAPP';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Send a ${chLabel(channel)} test'),
        content: TextField(
            key: const ValueKey('org-test-target'),
            controller: target,
            decoration: InputDecoration(labelText: phone ? 'Phone number (E.164)' : 'User id with a registered device')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final t = target.text.trim();
    await runAction(context, () => org.testOrgChannel(channel, phone: phone ? t : null, userId: phone ? null : t), done: 'Test sent');
  }
}

// =========================================================================== C1-C3 preferences & member app

/// Notification preferences per group (add-only) and the member app settings for C1-C3.
class OrgPreferencesTab extends StatefulWidget {
  final NotificationApi org;
  const OrgPreferencesTab({super.key, required this.org});
  @override
  State<OrgPreferencesTab> createState() => OrgPreferencesTabState();
}

class OrgPreferencesTabState extends State<OrgPreferencesTab> {
  final key = GlobalKey();
  final pending = <String>{}; // "GROUP|CHANNEL"
  Json? edited;

  Future<(Json, Json)> _load() async {
    final r = await Future.wait([widget.org.orgPreferences(), widget.org.orgSettings()]);
    return (r[0], r[1]);
  }

  @override
  Widget build(BuildContext context) => Loaded<(Json, Json)>(
        key: key,
        load: _load,
        builder: (context, data, reload) {
          final (prefs, settingsRes) = data;
          final enabled = (prefs['enabledChannels'] as List).cast<String>();
          final groups = (prefs['groups'] as List).map((g) => Map<String, dynamic>.from(g as Map)).toList();
          final saved = Map<String, dynamic>.from(settingsRes['settings'] as Map);
          final s = edited ??= Map<String, dynamic>.from(saved);
          return ListView(children: [
            PageHeader('Notification preferences',
                subtitle: 'Which channels each group of notifications uses. Set when the organization was created; '
                    'you can add channels, not remove them.',
                actions: [
                  FilledButton(
                    key: const ValueKey('prefs-add'),
                    onPressed: pending.isEmpty ? null : () => _add(context, reload),
                    child: Text(pending.isEmpty ? 'Add channels' : 'Add ${pending.length}'),
                  ),
                ]),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DataTable(columns: [
                const DataColumn(label: Text('Group')),
                for (final c in kChannels) DataColumn(label: Text(chLabel(c))),
              ], rows: [
                for (final g in groups)
                  DataRow(cells: [
                    DataCell(Text(g['group'] as String)),
                    for (final c in kChannels) DataCell(_cell(g, c, enabled)),
                  ]),
              ]),
            ),
            const Divider(height: 32),
            const PageHeader('Member app',
                subtitle: 'How the inbox, preferences and push prompt behave in the member app. Values can be raised, not lowered.'),
            _settingsForm(context, saved, s, reload),
          ]);
        },
      );

  Widget _cell(Json g, String c, List<String> enabled) {
    final group = g['group'] as String;
    final row = (g['channels'] as List).cast<Map>().where((x) => x['channel'] == c).toList();
    if (row.isNotEmpty) {
      return Tooltip(
        message: row.first['source'] == 'ADDED' ? 'Added' : 'Provisioned',
        child: Icon(Icons.lock, key: ValueKey('pref-locked-$group-$c'), size: 18),
      );
    }
    if (!enabled.contains(c)) return const Text('—');
    final k = '$group|$c';
    return Checkbox(
      key: ValueKey('pref-$group-$c'),
      value: pending.contains(k),
      onChanged: (v) => setState(() => v == true ? pending.add(k) : pending.remove(k)),
    );
  }

  Future<void> _add(BuildContext context, Future<void> Function() reload) async {
    final items = [
      for (final k in pending) {'group': k.split('|')[0], 'channel': k.split('|')[1]}
    ];
    if (!await confirm(context,
        title: 'Add ${items.length} channel(s)?', message: 'Added channels cannot be removed later.', action: 'Add')) {
      return;
    }
    if (context.mounted && await runAction(context, () => widget.org.addOrgPreferences(items), done: 'Channels added')) {
      setState(pending.clear);
      await reload();
    }
  }

  Widget _settingsForm(BuildContext context, Json saved, Json s, Future<void> Function() reload) {
    final retention = (saved['inbox_retention_days'] as num?)?.toInt() ?? 90;
    const retentionOptions = [30, 60, 90, 180, 365, 730, 3650];
    final prompts = const {'off': 'Never ask', 'after_first_notification': 'After the first notification', 'first_login': 'At first login'};
    final explanation = TextEditingController(text: s['push_explanation'] as String? ?? '');
    bool lowered(String k) => saved[k] == true && s[k] != true;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DropdownButtonFormField<int>(
          isExpanded: true,
          key: const ValueKey('set-retention'),
          initialValue: (s['inbox_retention_days'] as num?)?.toInt() ?? retention,
          decoration: const InputDecoration(labelText: 'Keep inbox notifications for'),
          items: [
            for (final d in {...retentionOptions, retention}.toList()..sort())
              DropdownMenuItem(value: d, enabled: d >= retention, child: Text('$d days')),
          ],
          onChanged: (v) => setState(() => s['inbox_retention_days'] = v),
        ),
        SwitchListTile(
          key: const ValueKey('set-badge'),
          title: const Text('Unread badge on the bell'),
          value: s['unread_badge'] == true,
          onChanged: saved['unread_badge'] == true ? null : (v) => setState(() => s['unread_badge'] = v),
        ),
        SwitchListTile(
          key: const ValueKey('set-group-day'),
          title: const Text('Group the inbox by day'),
          value: s['group_by_day'] == true,
          onChanged: saved['group_by_day'] == true ? null : (v) => setState(() => s['group_by_day'] = v),
        ),
        SwitchListTile(
          key: const ValueKey('set-members-change'),
          title: const Text('Members can turn channels off'),
          subtitle: const Text('Off: members only give consent; the organization\'s choice applies.'),
          value: s['members_can_change'] == true,
          onChanged: saved['members_can_change'] == true ? null : (v) => setState(() => s['members_can_change'] = v),
        ),
        DropdownButtonFormField<String>(
          isExpanded: true,
          key: const ValueKey('set-push-prompt'),
          initialValue: s['push_prompt'] as String? ?? 'off',
          decoration: const InputDecoration(labelText: 'Ask for push permission'),
          items: [
            for (final e in prompts.entries)
              DropdownMenuItem(value: e.key, enabled: !(e.key == 'off' && saved['push_prompt'] != 'off'), child: Text(e.value)),
          ],
          onChanged: (v) => setState(() => s['push_prompt'] = v),
        ),
        TextField(
          key: const ValueKey('set-push-explanation'),
          controller: explanation,
          maxLength: 200,
          decoration: const InputDecoration(labelText: 'Text shown before the push permission prompt'),
          onChanged: (v) => s['push_explanation'] = v,
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('set-save'),
          onPressed: () async {
            if (lowered('unread_badge') || lowered('group_by_day') || lowered('members_can_change')) {
              return toast(context, 'Provisioned settings cannot be lowered');
            }
            final patch = <String, dynamic>{
              for (final k in ['inbox_retention_days', 'unread_badge', 'group_by_day', 'push_prompt', 'push_explanation', 'members_can_change'])
                if (s[k] != saved[k]) k: s[k],
            };
            if (patch.isEmpty) return toast(context, 'Nothing changed');
            if (await runAction(context, () => widget.org.saveOrgSettings(patch), done: 'Member app settings saved')) {
              edited = null;
              await reload();
            }
          },
          child: const Text('Save member app settings'),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

// =========================================================================== B5 delivery log

class DeliveryLogTab extends StatelessWidget {
  final NotificationApi org;
  const DeliveryLogTab({super.key, required this.org});

  static Color? statusColor(String s) => switch (s) {
        'DELIVERED' || 'ACCEPTED' => Colors.green,
        'FAILED' => Colors.red,
        'QUEUED' || 'PROCESSING' => Colors.orange,
        _ => null,
      };

  @override
  Widget build(BuildContext context) => Loaded<List<Json>>(
        load: () => org.adminList('deliveries'),
        builder: (context, rows, reload) => ListView(children: [
          PageHeader('Delivery log',
              subtitle: 'The latest notifications sent to this organization\'s members, per channel.',
              actions: [IconButton(tooltip: 'Refresh', onPressed: reload, icon: const Icon(Icons.refresh))]),
          if (rows.isEmpty) const ListTile(title: Text('Nothing sent yet')),
          for (final d in rows)
            ListTile(
              key: ValueKey('delivery-${d['id']}'),
              leading: channelChip(d['channel'] as String),
              title: Text(((d['notification'] as Map?)?['title'] ?? '').toString()),
              subtitle: Text('To ${(d['notification'] as Map?)?['user_id'] ?? '?'} · ${d['attempts'] ?? 0} attempt(s)'),
              trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
                statusChip(d['status'] as String, color: statusColor(d['status'] as String)),
                IconButton(
                  key: ValueKey('delivery-attempts-${d['id']}'),
                  tooltip: 'Attempts',
                  icon: const Icon(Icons.list_alt),
                  onPressed: () => _attempts(context, d['id'] as String),
                ),
                if (d['status'] == 'FAILED' || d['status'] == 'UNKNOWN')
                  IconButton(
                    key: ValueKey('delivery-retry-${d['id']}'),
                    tooltip: 'Retry',
                    icon: const Icon(Icons.replay),
                    onPressed: () async {
                      if (await runAction(context, () => org.retryDelivery(d['id'] as String), done: 'Queued for retry')) await reload();
                    },
                  ),
              ]),
            ),
        ]),
      );

  Future<void> _attempts(BuildContext context, String id) async {
    List<Json> attempts = [];
    if (!await runAction(context, () async => attempts = await org.deliveryAttempts(id)) || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Attempts'),
        content: SizedBox(
          width: 420,
          child: attempts.isEmpty
              ? const Text('No attempts yet')
              : ListView(shrinkWrap: true, children: [
                  for (final a in attempts)
                    ListTile(
                      dense: true,
                      title: Text('#${a['attempt'] ?? '?'} ${a['outcome'] ?? ''} · ${a['created_at'] ?? ''}'),
                      subtitle: a['error'] == null ? null : Text('${a['error']}'),
                    ),
                ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }
}

// =========================================================================== B6 audit

class OrgAuditTab extends StatelessWidget {
  final NotificationApi org;
  const OrgAuditTab({super.key, required this.org});

  @override
  Widget build(BuildContext context) => Loaded<List<Json>>(
        load: () => org.adminList('audit'),
        builder: (context, rows, reload) => ListView(children: [
          const PageHeader('Audit', subtitle: 'Every change made to this organization\'s notifications, newest first.'),
          if (rows.isEmpty) const ListTile(title: Text('No changes yet')),
          for (final a in rows)
            ListTile(
              key: ValueKey('audit-${a['id']}'),
              dense: true,
              title: Text(a['action'] as String? ?? ''),
              subtitle: Text('${a['actor'] ?? ''} · ${a['created_at'] ?? ''}'),
            ),
        ]),
      );
}
