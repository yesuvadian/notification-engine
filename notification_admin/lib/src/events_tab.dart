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

  /// Events grouped by the product's module (e.g. UPKEEP, VISITORS), groups and events sorted.
  Map<String, List<String>> get groups {
    final out = <String, List<String>>{};
    for (final code in events) {
      final m = d.events.firstWhere((e) => e['code'] == code)['module_code']?.toString() ?? '';
      (out[m.isEmpty ? 'OTHER' : m] ??= []).add(code);
    }
    return Map.fromEntries(out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  String roleName(String? code) {
    for (final r in roles) {
      if (r['code'] == code) return '${r['name'] ?? code}';
    }
    return code ?? '?';
  }

  /// People linked to the record that the product sends with [code] (event metadata
  /// recipientAttributes, e.g. Flat owner, Task creator): [{code, label}].
  List<Json> recordPeople(String code) {
    final version = latestEventVersion(code);
    final event = d.events
        .where((e) => e['code'] == code && ((e['version'] as num?)?.toInt() ?? 1) == version)
        .firstOrNull;
    final metadata = event?['metadata'];
    final list = metadata is Map ? metadata['recipientAttributes'] : null;
    return [
      for (final a in (list is List ? list : const []))
        if (a is Map && a['code'] is String) Map<String, dynamic>.from(a),
    ];
  }

  String recordPersonLabel(String event, String code) =>
      '${recordPeople(event).where((a) => a['code'] == code).firstOrNull?['label'] ?? code}';

  /// Record people a rule also notifies (attribute_codes).
  static List<String> ruleAttributes(Json rule) => [
        for (final c in (rule['attribute_codes'] as List? ?? const []))
          if (c is String && c.isNotEmpty) c,
      ];

  /// Numbers an admin listed on a rule (custom_phones, E.164).
  static List<String> rulePhones(Json rule) => [
        for (final c in (rule['custom_phones'] as List? ?? const []))
          if (c is String && c.isNotEmpty) c,
      ];

  /// The roles of an "Everyone with a role" rule: role_codes, else the older single role_code.
  static List<String> ruleRoles(Json rule) {
    final many = [
      for (final c in (rule['role_codes'] as List? ?? const []))
        if (c is String && c.isNotEmpty) c,
    ];
    if (many.isNotEmpty) return many.toSet().toList();
    final one = rule['role_code'];
    return one is String && one.isNotEmpty ? [one] : const [];
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

  /// Open every event card (tests and screenshots); by default cards start collapsed.
  final bool expandEvents;
  const EventsTab({super.key, required this.org, required this.organizationName, this.expandEvents = false});

  @override
  Widget build(BuildContext context) => Loaded<EventsData>(
        load: () => loadEvents(org),
        builder: (context, e, reload) {
          final pc = (org.productCode ?? '').toUpperCase();
          return ListView(children: [
            PageHeader('Notifications',
                subtitle: '$pc events grouped by area; open an event to change it. Choose who gets it, turn channels on, and change the wording. '
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
            for (final MapEntry(key: module, value: codes) in e.groups.entries)
              _Group(
                  module: module,
                  codes: codes,
                  data: e,
                  children: [
                    for (final ev in codes) _EventCard(org: org, event: ev, data: e, reload: reload, expanded: expandEvents),
                  ]),
            const SizedBox(height: 24),
          ]);
        },
      );
}

/// One area of the product (its module), open by default, with how many of its events are on.
class _Group extends StatelessWidget {
  final String module;
  final List<String> codes;
  final EventsData data;
  final List<Widget> children;
  const _Group({required this.module, required this.codes, required this.data, required this.children});

  @override
  Widget build(BuildContext context) {
    final on = codes.where((c) => data.rulesFor(c).firstOrNull?['active'] == true).length;
    return ExpansionTile(
      key: PageStorageKey('group-$module'),
      initiallyExpanded: true,
      maintainState: true,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: EdgeInsets.zero,
      title: Text(eventLabel(module), key: ValueKey('group-title-$module'), style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text('${codes.length} event${codes.length == 1 ? '' : 's'} · $on on', style: Theme.of(context).textTheme.bodySmall),
      children: children,
    );
  }
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
  final bool expanded;
  const _EventCard({required this.org, required this.event, required this.data, required this.reload, this.expanded = false});

  String get pc => (org.productCode ?? '').toUpperCase();

  /// One line for the collapsed card: who gets it, channels on, and where the wording comes from.
  List<Widget> _summary(BuildContext context, Json? rule) {
    if (rule == null) return [Text('Not set up', style: Theme.of(context).textTheme.bodySmall)];
    final strategy = rule['recipient_strategy'];
    final base = strategy == 'ALL_USERS_IN_ROLE'
        ? EventsData.ruleRoles(rule).map(data.roleName).join(', ')
        : strategy == 'ALL_ORG_USERS'
            ? 'Everyone'
            : strategy == 'NONE'
                ? null
                : 'Decided by $pc';
    final people = EventsData.ruleAttributes(rule).map((c) => data.recordPersonLabel(event, c)).toList();
    final phones = EventsData.rulePhones(rule).length;
    final who = [
      if (base != null) base,
      ...people,
      if (phones > 0) '$phones ${phones == 1 ? 'number' : 'numbers'}',
    ].join(' + ');
    final bound = data.d.bindings.where((b) => b['rule_id'] == rule['id']).toList()
      ..sort((a, b) => kChannels.indexOf(a['channel'] as String) - kChannels.indexOf(b['channel'] as String));
    final own = bound.where((b) => data.override(b['template_id'] as String, b['channel'] as String) != null).length;
    return [
      Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.group_outlined, size: 14),
        const SizedBox(width: 4),
        Text(who, style: Theme.of(context).textTheme.bodySmall),
      ]),
      if (bound.isEmpty) Text('No channel', style: Theme.of(context).textTheme.bodySmall),
      for (final b in bound)
        _Tag(chLabel(b['channel'] as String).toUpperCase(), channelStyles[b['channel']]!.color),
      if (bound.isNotEmpty)
        own == 0 ? const _Tag('PLATFORM WORDING', kPlatformColor) : _Tag(own == bound.length ? 'ORG WORDING' : 'ORG WORDING ON $own', kOrgColor),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules = data.rulesFor(event);
    final rule = rules.firstOrNull;
    final on = rule?['active'] == true;
    final header = Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(eventLabel(event), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            Text(event, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.outline)),
          ]),
          const SizedBox(height: 4),
          Wrap(key: ValueKey('event-summary-$event'), spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: _summary(context, rule)),
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
    ]);
    if (rule == null) {
      return Card(
        key: ValueKey('event-$event'),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 12, 10), child: header),
      );
    }
    return Card(
      key: ValueKey('event-$event'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('event-tile-$event'),
        initiallyExpanded: expanded,
        maintainState: true,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        controlAffinity: ListTileControlAffinity.leading,
        title: header,
        children: [
          const Divider(height: 1),
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
    final chosen = EventsData.ruleRoles(rule);
    final known = [for (final c in chosen) if (roles.any((r) => r['code'] == c)) c];
    final gone = [for (final c in chosen) if (!known.contains(c)) c];
    Future<void> setRoles(List<String> codes) async {
      if (codes.isEmpty) return toast(context, 'Keep at least one role, or choose another kind of recipient');
      final sorted = [...codes]..sort();
      if (await runAction(context, () => org.updateRule(id, {'role_codes': sorted}), done: 'Roles saved')) await reload();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: [
     Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.end, children: [
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
            const DropdownMenuItem(value: 'NONE', child: Text('Only the people chosen below')),
          ],
          onChanged: (v) async {
            if (v == null || v == strategy) return;
            if (v == 'ALL_USERS_IN_ROLE' && roles.isEmpty) return toast(context, '$pc has not shared any roles for this organization yet');
            final patch = {
              'recipient_strategy': v,
              if (v == 'ALL_USERS_IN_ROLE') 'role_codes': known.isNotEmpty ? known : [roles.first['code']],
            };
            if (await runAction(context, () => org.updateRule(id, patch), done: 'Recipients saved')) await reload();
          },
        ),
      ),
      if (strategy == 'ALL_USERS_IN_ROLE')
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: InputDecorator(
            key: ValueKey('roles-$id'),
            decoration: InputDecoration(
              labelText: 'Roles (members of any of them)',
              helperText: gone.isEmpty ? null : 'No longer a role here: ${gone.join(', ')}',
            ),
            child: Wrap(spacing: 8, runSpacing: 6, children: [
              for (final r in roles)
                FilterChip(
                  key: ValueKey('role-$id-${r['code']}'),
                  label: Text('${r['name'] ?? r['code']}'),
                  selected: known.contains(r['code']),
                  onSelected: (on) => setRoles(on ? [...known, r['code'] as String] : ([...known]..remove(r['code']))),
                ),
            ]),
          ),
        ),
      if (strategy == 'RECIPIENTS')
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('$pc sends the people with each event, from its own role settings.',
              style: Theme.of(context).textTheme.bodySmall),
        ),
     ]),
     _AlsoNotify(org: org, rule: rule, data: data, reload: reload),
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


/// E.164 for a typed number: +<country><number>; a 10-digit Indian mobile (or 0 / 91 + it) gets +91.
/// Null when it is not a phone number. Same rule as the engine API.
String? normalizePhone(String value) {
  final raw = value.trim();
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  String? out;
  if (raw.startsWith('+')) {
    out = '+$digits';
  } else if (RegExp(r'^[6-9][0-9]{9}$').hasMatch(digits)) {
    out = '+91$digits';
  } else if (RegExp(r'^0[6-9][0-9]{9}$').hasMatch(digits)) {
    out = '+91${digits.substring(1)}';
  } else if (RegExp(r'^91[6-9][0-9]{9}$').hasMatch(digits)) {
    out = '+$digits';
  }
  return out != null && RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(out) ? out : null;
}

/// "Also notify": people linked to the record (from the product, e.g. Flat owner, Task creator) and phone
/// numbers the admin lists (a vendor, an agency). Added to whoever the recipients above are.
class _AlsoNotify extends StatefulWidget {
  final NotificationApi org;
  final Json rule;
  final EventsData data;
  final Future<void> Function() reload;
  const _AlsoNotify({required this.org, required this.rule, required this.data, required this.reload});

  @override
  State<_AlsoNotify> createState() => _AlsoNotifyState();
}

class _AlsoNotifyState extends State<_AlsoNotify> {
  final _phone = TextEditingController();

  String get id => widget.rule['id'] as String;
  String get event => '${widget.rule['event_code']}';

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save(Map<String, dynamic> patch, String done) async {
    if (await runAction(context, () => widget.org.updateRule(id, patch), done: done)) await widget.reload();
  }

  Future<void> _add(List<String> phones) async {
    final phone = normalizePhone(_phone.text);
    if (phone == null) return toast(context, 'Enter a phone number, e.g. +91 98765 43210');
    if (phones.contains(phone)) return toast(context, '$phone is already on the list');
    if (phones.length >= 20) return toast(context, 'Up to 20 numbers per notification');
    await _save({'custom_phones': [...phones, phone]}, 'Number added');
    if (mounted) _phone.clear();
  }

  @override
  Widget build(BuildContext context) {
    final pc = (widget.org.productCode ?? 'The product').toUpperCase();
    final small = Theme.of(context).textTheme.bodySmall;
    final people = widget.data.recordPeople(event);
    final chosen = EventsData.ruleAttributes(widget.rule);
    final phones = EventsData.rulePhones(widget.rule);
    return Column(
      key: ValueKey('also-$id'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text('Also notify', style: Theme.of(context).textTheme.titleSmall),
        if (people.isEmpty)
          Text('$pc sends no people linked to this event.', style: small)
        else
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final p in people)
              FilterChip(
                key: ValueKey('attr-$id-${p['code']}'),
                avatar: const Icon(Icons.person_pin_outlined, size: 18),
                label: Text('${p['label'] ?? p['code']}'),
                tooltip: p['note'] as String?,
                selected: chosen.contains(p['code']),
                onSelected: (on) {
                  final next = on ? [...chosen, p['code'] as String] : ([...chosen]..remove(p['code']));
                  _save({'attribute_codes': next..sort()}, 'Saved');
                },
              ),
          ]),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final phone in phones)
            InputChip(
              key: ValueKey('phone-$id-$phone'),
              avatar: const Icon(Icons.phone_outlined, size: 18),
              label: Text(phone),
              deleteIcon: const Icon(Icons.close, size: 18),
              deleteButtonTooltipMessage: 'Remove $phone',
              onDeleted: () => _save({'custom_phones': [...phones]..remove(phone)}, 'Number removed'),
            ),
          SizedBox(
            width: 220,
            child: TextField(
              key: ValueKey('phone-input-$id'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Add a phone number', hintText: '+91 98765 43210', isDense: true),
              onSubmitted: (_) => _add(phones),
            ),
          ),
          TextButton.icon(
            key: ValueKey('phone-add-$id'),
            onPressed: () => _add(phones),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add number'),
          ),
        ]),
        Text('SMS and WhatsApp go to these numbers when the channel is on for the organization. '
            'Add only numbers whose owners agreed to get them.', style: small),
      ],
    );
  }
}
