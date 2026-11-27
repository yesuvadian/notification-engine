import 'package:flutter/material.dart';
import 'package:notification_sdk/notification_sdk.dart';

import 'common.dart';
import 'designer.dart';
import 'platform_api.dart';
import 'workspace.dart';

/// "UPKEEP_TASK_DUE" -> "Upkeep task due".
String eventLabel(String code) {
  final s = code.toLowerCase().replaceAll('_', ' ').trim();
  return s.isEmpty ? code : s[0].toUpperCase() + s.substring(1);
}

/// Everything the Notifications tab shows for one organization.
class EventsData {
  final RulesData d;
  final List<Json> overrides;

  /// The organization's roles as its product synced them (the product owns role mapping).
  final List<Json> roles;
  EventsData(this.d, this.overrides, this.roles);

  List<String> get events => d.events.map((e) => e['code'] as String).toSet().toList()..sort();

  int latestEventVersion(String code) => d.events
      .where((e) => e['code'] == code)
      .fold<int>(1, (m, e) => ((e['version'] as num?)?.toInt() ?? 1) > m ? (e['version'] as num).toInt() : m);

  List<Json> rulesFor(String code) {
    final r = d.rules.where((x) => x['event_code'] == code).toList();
    r.sort((a, b) => (b['active'] == true ? 1 : 0) - (a['active'] == true ? 1 : 0));
    return r;
  }

  Json? binding(String ruleId, String channel) {
    for (final b in d.bindings) {
      if (b['rule_id'] == ruleId && b['channel'] == channel) return b;
    }
    return null;
  }

  Json? override(String templateId, String channel) {
    for (final o in overrides) {
      if (o['template_id'] == templateId && o['channel'] == channel && o['status'] == 'PUBLISHED') return o;
    }
    return null;
  }

  int latestTemplateVersion(String templateId, String channel) => d.templates
      .where((v) => v['template_id'] == templateId && v['channel'] == channel && v['status'] == 'PUBLISHED')
      .fold<int>(0, (m, v) => (v['version'] as int) > m ? v['version'] as int : m);

  /// The platform template a channel gets when it is turned on for [event]: the template the rule already uses
  /// on another channel, else `<product>_<event>`, else `<product>_message`, else any published one.
  Json? suggestedTemplate(String productCode, String event, String channel, String? ruleId) {
    final options = d.templatesFor(channel);
    if (options.isEmpty) return null;
    String? codeOf(Json v) => (v['template'] is Map ? (v['template'] as Map)['code'] : null)?.toString().toLowerCase();
    final used = ruleId == null ? <String>{} : d.bindings.where((b) => b['rule_id'] == ruleId).map((b) => b['template_id']).toSet();
    final pc = productCode.toLowerCase();
    return options.where((v) => used.contains(v['template_id'])).firstOrNull ??
        options.where((v) => codeOf(v) == '${pc}_${event.toLowerCase()}').firstOrNull ??
        options.where((v) => codeOf(v) == '${pc}_message').firstOrNull ??
        options.first;
  }

  List<Json> get selectableRoles => roles.where((r) => r['active'] != false && r['notification_admin'] != true).toList()
    ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
}

Future<EventsData> loadEvents(NotificationApi org) async {
  final r = await Future.wait([
    loadRules(org),
    org.adminList('overrides'),
    org.adminList('roles').catchError((_) => <Json>[]),
  ]);
  return EventsData(r[0] as RulesData, r[1] as List<Json>, r[2] as List<Json>);
}

/// One place per event: who gets it, on which channels, and the wording. The platform template (shared) and this
/// organization's own wording (override) are shown side by side for every channel.
class EventsTab extends StatelessWidget {
  final NotificationApi org;
  final String organizationName;
  const EventsTab({super.key, required this.org, required this.organizationName});

  @override
  Widget build(BuildContext context) => Loaded<EventsData>(
        load: () => loadEvents(org),
        builder: (context, e, reload) {
          final pc = (org.productCode ?? '').toUpperCase();
          return ListView(children: [
            PageHeader('Notifications',
                subtitle: 'One card per $pc event. Choose who gets it, turn channels on, and change the wording. '
                    'Platform wording is shared by every organization; organization wording changes it for $organizationName only.',
                actions: [
                  if (setupPlan(e.d, org.productCode ?? '').values.where((v) => v != null).length > 1)
                    OutlinedButton.icon(
                        key: const ValueKey('events-setup-all'),
                        onPressed: () async {
                          final r = await setUpNotifications(org);
                          if (context.mounted) {
                            toast(context, '${r.created} events set up${r.failed.isEmpty ? '' : ', ${r.failed.length} failed (${r.failed.first})'}');
                          }
                          await reload();
                        },
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('Set up all events')),
                ]),
            const _Legend(),
            if (e.events.isEmpty) const ListTile(title: Text('This product has not registered any events yet')),
            for (final ev in e.events) _EventCard(org: org, event: ev, data: e, reload: reload),
            const SizedBox(height: 24),
          ]);
        },
      );
}

class _Legend extends StatelessWidget {
  const _Legend();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Wrap(spacing: 16, runSpacing: 6, children: const [
          _Tag('PLATFORM', kPlatformColor, 'shared wording from the platform template'),
          _Tag('ORGANIZATION', kOrgColor, "this organization's own wording (override)"),
        ]),
      );
}

const kPlatformColor = Color(0xFF16A34A);
const kOrgColor = Color(0xFFCA8A04);

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  final String? explain;
  const _Tag(this.text, this.color, [this.explain]);
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: color.withAlpha(28), borderRadius: BorderRadius.circular(5), border: Border.all(color: color.withAlpha(120))),
          child: Text(text, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: color)),
        ),
        if (explain != null) ...[const SizedBox(width: 6), Text(explain!, style: Theme.of(context).textTheme.bodySmall)],
      ]);
}

class _EventCard extends StatelessWidget {
  final NotificationApi org;
  final String event;
  final EventsData data;
  final Future<void> Function() reload;
  const _EventCard({required this.org, required this.event, required this.data, required this.reload});

  String get pc => (org.productCode ?? '').toUpperCase();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules = data.rulesFor(event);
    final rule = rules.firstOrNull;
    final on = rule?['active'] == true;
    return Card(
      key: ValueKey('event-$event'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(eventLabel(event), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                Text(event, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
              ]),
            ),
            if (rule == null)
              FilledButton.icon(
                  key: ValueKey('event-setup-$event'),
                  onPressed: () => _setUp(context),
                  icon: const Icon(Icons.power_settings_new, size: 16),
                  label: const Text('Set up'))
            else ...[
              Text(on ? 'On' : 'Off', style: theme.textTheme.labelLarge),
              Switch(key: ValueKey('event-active-$event'), value: on, onChanged: (v) => _setActive(context, rule, v)),
              PopupMenuButton<String>(
                key: ValueKey('event-menu-$event'),
                onSelected: (_) => _delete(context, rule),
                itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Remove this setup'))],
              ),
            ],
          ]),
          if (rule == null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Not set up: nobody in this organization gets this notification.', style: theme.textTheme.bodySmall),
            )
          else ...[
            const SizedBox(height: 10),
            _section(context, '1', 'Who gets it'),
            _WhoGetsIt(org: org, rule: rule, data: data, reload: reload),
            if (rules.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${rules.length - 1} more rule(s) for this event are not shown here.', style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: 12),
            _section(context, '2', 'Channels and wording'),
            for (final c in data.d.channels.map((c) => c['channel'] as String).toList()..sort((a, b) => kChannels.indexOf(a) - kChannels.indexOf(b)))
              _ChannelRow(org: org, event: event, rule: rule, channel: c, data: data, reload: reload),
          ],
        ]),
      ),
    );
  }

  Widget _section(BuildContext context, String n, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          CircleAvatar(radius: 9, child: Text(n, style: const TextStyle(fontSize: 11))),
          const SizedBox(width: 8),
          Text(title, style: Theme.of(context).textTheme.titleSmall),
        ]),
      );

  Future<void> _setUp(BuildContext context) async {
    final tpl = data.suggestedTemplate(org.productCode ?? '', event, 'IN_APP', null);
    if (tpl == null) return toast(context, 'No published in-app platform template yet. Publish one in Notification Engine › Templates.');
    final ok = await runAction(context, () async {
      final rule = await org.createRule({
        'event_code': event,
        'event_version': data.latestEventVersion(event),
        'recipient_strategy': 'RECIPIENTS',
        'purpose': event.toLowerCase(),
        'active': false,
      });
      await org.bindChannel(rule['id'] as String, 'IN_APP', tpl['template_id'] as String, version: tpl['version'] as int);
      await org.updateRule(rule['id'] as String, {'active': true});
    }, done: '${eventLabel(event)} is on (in-app)');
    if (ok) await reload();
  }

  Future<void> _setActive(BuildContext context, Json rule, bool v) async {
    if (v && !data.d.bindings.any((b) => b['rule_id'] == rule['id'])) return toast(context, 'Turn on at least one channel first');
    if (await runAction(context, () => org.updateRule(rule['id'] as String, {'active': v}), done: v ? 'On' : 'Off')) await reload();
  }

  Future<void> _delete(BuildContext context, Json rule) async {
    if (!await confirm(context,
        title: 'Remove ${eventLabel(event)}?', message: 'Nobody in this organization will get this notification until it is set up again.', action: 'Remove')) {
      return;
    }
    if (context.mounted && await runAction(context, () => org.deleteRule(rule['id'] as String), done: 'Removed')) await reload();
  }
}

/// Recipient choice. Roles come from the product (synced into the engine), shown by name.
class _WhoGetsIt extends StatelessWidget {
  final NotificationApi org;
  final Json rule;
  final EventsData data;
  final Future<void> Function() reload;
  const _WhoGetsIt({required this.org, required this.rule, required this.data, required this.reload});

  String get id => rule['id'] as String;

  @override
  Widget build(BuildContext context) {
    final pc = (org.productCode ?? 'the product').toUpperCase();
    final strategy = rule['recipient_strategy'] as String? ?? 'RECIPIENTS';
    final roles = data.selectableRoles;
    final role = rule['role_code'] as String?;
    final known = roles.any((r) => r['code'] == role);
    return Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.end, children: [
      SizedBox(
        width: 340,
        child: DropdownButtonFormField<String>(
          key: ValueKey('who-$id'),
          isExpanded: true,
          initialValue: strategy,
          decoration: const InputDecoration(labelText: 'Recipients'),
          items: [
            DropdownMenuItem(value: 'RECIPIENTS', child: Text('Decided by $pc (its notification roles)')),
            const DropdownMenuItem(value: 'ALL_USERS_IN_ROLE', child: Text('Everyone with a role')),
            const DropdownMenuItem(value: 'ALL_ORG_USERS', child: Text('Everyone in the organization')),
          ],
          onChanged: (v) async {
            if (v == null || v == strategy) return;
            if (v == 'ALL_USERS_IN_ROLE' && roles.isEmpty) return toast(context, '$pc has not shared any roles for this organization yet');
            final patch = {'recipient_strategy': v, if (v == 'ALL_USERS_IN_ROLE') 'role_code': known ? role : roles.first['code']};
            if (await runAction(context, () => org.updateRule(id, patch), done: 'Recipients saved')) await reload();
          },
        ),
      ),
      if (strategy == 'ALL_USERS_IN_ROLE')
        SizedBox(
          width: 280,
          child: DropdownButtonFormField<String>(
            key: ValueKey('role-$id'),
            isExpanded: true,
            initialValue: known ? role : null,
            decoration: InputDecoration(labelText: 'Role', helperText: known || role == null ? null : 'Role $role no longer exists'),
            items: [for (final r in roles) DropdownMenuItem(value: r['code'] as String, child: Text('${r['name'] ?? r['code']}'))],
            onChanged: (v) async {
              if (v == null || v == role) return;
              if (await runAction(context, () => org.updateRule(id, {'role_code': v}), done: 'Role saved')) await reload();
            },
          ),
        ),
      if (strategy == 'RECIPIENTS')
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('$pc sends the people with each event, from its own role settings.',
              style: Theme.of(context).textTheme.bodySmall),
        ),
    ]);
  }
}

/// One channel of one event: on/off, then the platform wording and this organization's wording side by side.
class _ChannelRow extends StatelessWidget {
  final NotificationApi org;
  final String event, channel;
  final Json rule;
  final EventsData data;
  final Future<void> Function() reload;
  const _ChannelRow({required this.org, required this.event, required this.rule, required this.channel, required this.data, required this.reload});

  String get ruleId => rule['id'] as String;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final st = channelStyles[channel]!;
    final orgOn = data.d.channels.any((c) => c['channel'] == channel && c['enabled'] == true);
    final b = data.binding(ruleId, channel);
    final key = '$event-$channel';
    return Container(
      key: ValueKey('ch-$key'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: b != null ? st.color.withAlpha(110) : theme.colorScheme.outlineVariant),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final head = SizedBox(
          width: 175,
          child: Row(children: [
            Icon(st.icon, size: 18, color: b != null ? st.color : theme.colorScheme.outline),
            const SizedBox(width: 6),
            Expanded(child: Text(chLabel(channel), style: const TextStyle(fontWeight: FontWeight.w600))),
            Switch(
              key: ValueKey('ch-on-$key'),
              value: b != null,
              onChanged: orgOn ? (v) => v ? _turnOn(context) : _turnOff(context) : null,
            ),
          ]),
        );
        if (!orgOn) {
          return Row(children: [
            head,
            Expanded(child: Text('Off for the whole organization. Turn it on in "Channels on/off" first.', style: theme.textTheme.bodySmall)),
          ]);
        }
        if (b == null) {
          return Row(children: [head, Expanded(child: Text('Not sent on this channel.', style: theme.textTheme.bodySmall))]);
        }
        final tid = b['template_id'] as String;
        final pinned = b['template_version'] as int;
        final latest = data.latestTemplateVersion(tid, channel);
        final ov = data.override(tid, channel);
        final platform = _Panel(
          key: ValueKey('platform-$key'),
          tag: const _Tag('PLATFORM', kPlatformColor),
          title: '${data.d.templateName(tid)} · v$pinned',
          lines: [if (latest > pinned) 'v$latest is available'],
          actions: [
            if (latest > pinned)
              TextButton(key: ValueKey('upgrade-$key'), onPressed: () => _upgrade(context, tid, pinned, latest), child: Text('Upgrade to v$latest')),
          ],
          active: ov == null,
        );
        final orgPanel = _Panel(
          key: ValueKey('org-$key'),
          tag: const _Tag('ORGANIZATION', kOrgColor),
          title: ov == null ? 'Uses the platform wording' : 'Own wording (override v${ov['version']})',
          lines: const [],
          actions: [
            TextButton.icon(
                key: ValueKey('wording-$key'),
                onPressed: () => _editWording(context, tid, pinned),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: Text(ov == null ? 'Customise wording' : 'Edit wording')),
            if (ov != null)
              TextButton(key: ValueKey('reset-$key'), onPressed: () => _reset(context, ov), child: const Text('Back to platform wording')),
          ],
          active: ov != null,
        );
        final wide = c.maxWidth > 760;
        return wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                head,
                const SizedBox(width: 8),
                Expanded(child: platform),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 18), child: Icon(Icons.arrow_forward, size: 16)),
                Expanded(child: orgPanel),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [head, platform, const SizedBox(height: 6), orgPanel]);
      }),
    );
  }

  Future<void> _turnOn(BuildContext context) async {
    final tpl = data.suggestedTemplate(org.productCode ?? '', event, channel, ruleId);
    if (tpl == null) return toast(context, 'No published ${chLabel(channel)} platform template yet');
    if (await runAction(context, () => org.bindChannel(ruleId, channel, tpl['template_id'] as String, version: tpl['version'] as int),
        done: '${chLabel(channel)} on for ${eventLabel(event)}')) {
      await reload();
    }
  }

  Future<void> _turnOff(BuildContext context) async {
    final others = data.d.bindings.where((b) => b['rule_id'] == ruleId && b['channel'] != channel).length;
    if (others == 0 && rule['active'] == true) {
      if (!await confirm(context,
          title: 'Turn off the last channel?', message: '${eventLabel(event)} will also be turned off.', action: 'Turn off')) {
        return;
      }
      if (!context.mounted) return;
    }
    if (await runAction(context, () async {
      if (others == 0 && rule['active'] == true) await org.updateRule(ruleId, {'active': false});
      await org.unbindChannel(ruleId, channel);
    }, done: '${chLabel(channel)} off for ${eventLabel(event)}')) {
      await reload();
    }
  }

  Future<void> _editWording(BuildContext context, String tid, int pinned) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
            appBar: AppBar(title: Text('${eventLabel(event)} · ${chLabel(channel)} wording')),
            body: TemplateDesigner.override(
                api: org,
                template: {'id': tid, 'code': data.d.templateName(tid), 'name': data.d.templateName(tid)},
                baseVersion: pinned,
                eventCode: event,
                eventVersion: (rule['event_version'] as num?)?.toInt() ?? 1,
                initialChannel: channel))));
    await reload();
  }

  Future<void> _reset(BuildContext context, Json ov) async {
    if (!await confirm(context,
        title: 'Go back to platform wording?', message: "This organization's own ${chLabel(channel)} wording is removed (history is kept).", action: 'Reset')) {
      return;
    }
    if (context.mounted && await runAction(context, () => org.resetOverride(ov['id'] as String), done: 'Back to platform wording')) await reload();
  }

  Future<void> _upgrade(BuildContext context, String tid, int pinned, int latest) async {
    if (!await confirm(context,
        title: 'Upgrade to platform v$latest?',
        message: 'Every event in this organization using v$pinned of this template moves to v$latest. Own wording is carried over where the fields still exist.',
        action: 'Upgrade')) {
      return;
    }
    if (context.mounted && await runAction(context, () => org.upgradeTemplate(tid, version: latest), done: 'Upgraded to v$latest')) await reload();
  }
}

class _Panel extends StatelessWidget {
  final _Tag tag;
  final String title;
  final List<String> lines;
  final List<Widget> actions;
  final bool active;
  const _Panel({super.key, required this.tag, required this.title, required this.lines, required this.actions, required this.active});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
      decoration: BoxDecoration(
        color: active ? tag.color.withAlpha(16) : theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: active ? tag.color.withAlpha(140) : theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          tag,
          const Spacer(),
          if (active) Text('In use', style: theme.textTheme.labelSmall?.copyWith(color: tag.color, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Text(title, style: theme.textTheme.bodyMedium),
        for (final l in lines) Text(l, style: theme.textTheme.bodySmall),
        if (actions.isNotEmpty) Wrap(children: actions),
      ]),
    );
  }
}
