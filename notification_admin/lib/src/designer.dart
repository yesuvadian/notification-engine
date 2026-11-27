import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:notification_sdk/notification_sdk.dart';

import 'common.dart';
import 'platform_api.dart';

/// Renders `{{path}}` and `{{path | formatter}}` against sample data for the live preview.
/// Missing variables are shown as ⟨path⟩ and reported in [PreviewResult.missing].
class PreviewResult {
  final String text;
  final List<String> missing;
  const PreviewResult(this.text, this.missing);
}

PreviewResult renderPreview(String template, Map<String, dynamic> data) {
  final missing = <String>[];
  final out = template.replaceAllMapped(RegExp(r'{{\s*([\w.\[\]]+)\s*(?:\|\s*(\w+)(?::"([^"]*)")?)?\s*}}'), (m) {
    final path = m.group(1)!, f = m.group(2), arg = m.group(3);
    dynamic v = data;
    for (final k in path.split('.')) {
      v = v is Map ? v[k] : null;
    }
    if (v == null && f == 'default') return arg ?? '';
    if (v == null) {
      missing.add(path);
      return '⟨$path⟩';
    }
    switch (f) {
      case 'uppercase':
        return '$v'.toUpperCase();
      case 'lowercase':
        return '$v'.toLowerCase();
      case 'number':
        final n = num.tryParse('$v');
        if (n == null) return '$v';
        final s = n.toStringAsFixed(n % 1 == 0 ? 0 : 2);
        return s.replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+\d(\.|$))'), (x) => '${x[1]},'); // Indian grouping
      default:
        return '$v';
    }
  });
  return PreviewResult(out, missing);
}

/// SMS length and segment count (GSM 160 / 153 per segment).
String smsInfo(String text) {
  final n = text.length, seg = n <= 160 ? 1 : (n / 153).ceil();
  return '$n characters · $seg SMS segment${seg > 1 ? 's' : ''}';
}

/// Variable paths used in [text] (`{{path}}` or `{{path | formatter}}`).
Iterable<String> templatePaths(String text) =>
    RegExp(r'{{\s*([\w.\[\]]+)').allMatches(text).map((m) => m.group(1)!);

/// [data] with an example value for every path in [paths] that it does not have yet, so the preview shows
/// realistic text instead of "missing" for the variables the template already uses.
Map<String, dynamic> withSampleValues(Map<String, dynamic> data, Iterable<String> paths) {
  const examples = {
    'subject': 'Water tank cleaning tomorrow',
    'title': 'Water tank cleaning tomorrow',
    'body': 'Block A tank cleaning is scheduled for 10 AM. Water supply will be off for 2 hours.',
    'name': 'Anita Rao',
    'amount': 12500,
    'flat': 'B-402',
    'reference': 'RC-2291',
  };
  final out = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  for (final path in paths) {
    final keys = path.split('.');
    Map<String, dynamic> node = out;
    for (var i = 0; i < keys.length - 1; i++) {
      final next = node[keys[i]];
      if (next is! Map<String, dynamic>) {
        if (next != null) break;
        node[keys[i]] = <String, dynamic>{};
      }
      node = node[keys[i]] as Map<String, dynamic>;
    }
    node.putIfAbsent(keys.last, () => examples[keys.last] ?? 'Sample ${keys.last.replaceAll('_', ' ')}');
  }
  return out;
}

/// Look of each channel in the designer (same colours as the Notification Center).
class ChannelStyle {
  final IconData icon;
  final Color color;
  const ChannelStyle(this.icon, this.color);
}

const channelStyles = {
  'IN_APP': ChannelStyle(Icons.notifications_outlined, Color(0xFF9C4DCC)),
  'SMS': ChannelStyle(Icons.sms_outlined, Color(0xFF2E7D32)),
  'WHATSAPP': ChannelStyle(Icons.chat_outlined, Color(0xFF128C7E)),
  'PUSH': ChannelStyle(Icons.phone_iphone, Color(0xFFEF6C00)),
};

/// Fields each channel's content has, in the order the designer shows them.
const channelFields = {
  'IN_APP': ['title', 'body'],
  'SMS': ['body', 'msg91_template_id', 'dlt_template_id'],
  'WHATSAPP': ['template_name', 'language', 'params'],
  'PUSH': ['title', 'body', 'route'],
};

/// D5 / B7: template designer.
///
/// * [TemplateDesigner.platform] edits the platform template: saving creates or updates the draft version,
///   Publish makes it the version new organizations start on.
/// * [TemplateDesigner.override] edits one organization's override of the version it is pinned to: only the
///   fields changed are stored; Reset to platform removes the override.
class TemplateDesigner extends StatefulWidget {
  final NotificationPlatformApi? platformApi;
  final NotificationApi? orgApi;
  final Json template;
  final int? baseVersion;
  final String? eventCode;

  /// Event version whose variables the override designer offers (the rule's event_version).
  final int eventVersion;
  final String initialChannel;

  const TemplateDesigner.platform({super.key, required NotificationPlatformApi api, required this.template, this.initialChannel = 'IN_APP'})
      : platformApi = api,
        orgApi = null,
        baseVersion = null,
        eventCode = null,
        eventVersion = 1;

  const TemplateDesigner.override(
      {super.key,
      required NotificationApi api,
      required this.template,
      required int this.baseVersion,
      this.eventCode,
      this.eventVersion = 1,
      this.initialChannel = 'IN_APP'})
      : orgApi = api,
        platformApi = null;

  bool get isOverride => orgApi != null;

  @override
  State<TemplateDesigner> createState() => TemplateDesignerState();
}

class TemplateDesignerState extends State<TemplateDesigner> {
  late String channel = widget.initialChannel;
  final controllers = <String, TextEditingController>{};
  final sample = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert({
    'recipient': {'name': 'Anita Rao'},
    'data': {'amount': 12500, 'flat': 'B-402', 'reference': 'RC-2291'}
  }));
  Json base = {};
  Json? current;
  List<Json> variables = [];
  bool loading = true, busy = false;
  TextEditingController? focused;

  @override
  void initState() {
    super.initState();
    load();
  }

  List<Json> get versions => (widget.template['versions'] as List? ?? []).map((v) => Map<String, dynamic>.from(v as Map)).toList();

  Future<void> load() async {
    setState(() => loading = true);
    try {
      if (widget.isOverride) {
        final eff = await widget.orgApi!.effectiveTemplate(widget.template['id'] as String, channel);
        base = Map<String, dynamic>.from(eff['master']['content'] as Map);
        current = eff['override'] == null ? null : Map<String, dynamic>.from(eff['override'] as Map);
        final effective = Map<String, dynamic>.from(eff['effective'] as Map);
        _fill(effective);
        if (widget.eventCode != null && variables.isEmpty) {
          try {
            variables = await widget.orgApi!.eventVariables(widget.eventCode!, version: widget.eventVersion);
          } catch (_) {}
        }
      } else {
        final draft = versions.where((v) => v['channel'] == channel && v['status'] == 'DRAFT').toList();
        final published = versions.where((v) => v['channel'] == channel && v['status'] == 'PUBLISHED').toList()
          ..sort((a, b) => (b['version'] as int).compareTo(a['version'] as int));
        final src = draft.isNotEmpty ? draft.first : (published.isNotEmpty ? published.first : null);
        base = src == null ? {} : Map<String, dynamic>.from(src['content'] as Map);
        _fill(base);
      }
    } catch (e) {
      base = {};
      _fill({});
      if (mounted) toast(context, errorText(e));
    }
    _addSampleValues();
    if (mounted) setState(() => loading = false);
  }

  /// Gives the sample data a value for every variable the template already uses (on any channel),
  /// so the preview does not report the template's own variables as missing.
  void _addSampleValues() {
    try {
      final data = Map<String, dynamic>.from(jsonDecode(sample.text) as Map);
      final used = <String>{
        for (final c in kChannels) ...templatePaths(jsonEncode(_contentOf(c) ?? {})),
        ...templatePaths(jsonEncode(base)),
      };
      final next = withSampleValues(data, used);
      if (jsonEncode(next) != jsonEncode(data)) sample.text = const JsonEncoder.withIndent('  ').convert(next);
    } catch (_) {}
  }

  void _fill(Json content) {
    for (final f in channelFields[channel]!) {
      final v = content[f];
      final text = v == null ? '' : (v is String ? v : jsonEncode(v));
      (controllers[f] ??= TextEditingController()).text = text;
    }
  }

  Json content() {
    final c = <String, dynamic>{};
    for (final f in channelFields[channel]!) {
      final t = controllers[f]!.text;
      if (t.trim().isEmpty) continue;
      if (f == 'params') {
        try {
          c[f] = jsonDecode(t);
          continue;
        } catch (_) {}
      }
      c[f] = t;
    }
    return c;
  }

  /// Only the fields that differ from the platform version (what an override stores).
  Json patch() {
    final c = content(), p = <String, dynamic>{};
    for (final e in c.entries) {
      if (jsonEncode(base[e.key]) != jsonEncode(e.value)) p[e.key] = e.value;
    }
    return p;
  }

  void insertVariable(String path) {
    final c = focused ?? controllers[channelFields[channel]!.contains('body') ? 'body' : channelFields[channel]!.first]!;
    final sel = c.selection;
    final t = '{{$path}}';
    final start = sel.isValid ? sel.start : c.text.length, end = sel.isValid ? sel.end : c.text.length;
    c.value = TextEditingValue(text: c.text.replaceRange(start, end, t), selection: TextSelection.collapsed(offset: start + t.length));
    setState(() {});
  }

  Future<void> saveDraft() async {
    setState(() => busy = true);
    await runAction(context, () async {
      final saved = await widget.platformApi!.saveDraft(widget.template['id'] as String, channel, content());
      final list = <dynamic>[...?(widget.template['versions'] as List?)];
      list.removeWhere((v) => (v as Map)['channel'] == channel && v['version'] == saved['version']);
      list.add(saved);
      widget.template['versions'] = list;
    }, done: 'Draft saved');
    if (mounted) setState(() => busy = false);
  }

  Future<void> publish() async {
    final draft = versions.where((v) => v['status'] == 'DRAFT').map((v) => v['version'] as int).toSet();
    if (draft.isEmpty) {
      toast(context, 'Save a draft first');
      return;
    }
    final v = draft.first;
    if (!await confirm(context,
        title: 'Publish v$v?',
        message: 'New organizations start on v$v. Existing organizations stay on their version until you upgrade them.',
        action: 'Publish')) {
      return;
    }
    if (!mounted) return;
    await runAction(context, () async {
      await widget.platformApi!.publishVersion(widget.template['id'] as String, v);
      for (final x in (widget.template['versions'] as List)) {
        if ((x as Map)['version'] == v) x['status'] = 'PUBLISHED';
      }
    }, done: 'v$v published');
    if (mounted) setState(() {});
  }

  Future<void> publishOverride() async {
    final p = patch();
    if (p.isEmpty) {
      toast(context, 'Nothing changed from the platform template');
      return;
    }
    await runAction(context, () => widget.orgApi!.publishOverride(widget.template['id'] as String, widget.baseVersion!, channel, p),
        done: 'Override published');
    await load();
  }

  Future<void> resetOverride() async {
    if (current == null) return;
    if (!await confirm(context, title: 'Reset to platform?', message: 'The organization goes back to the platform template.', action: 'Reset')) return;
    if (!mounted) return;
    await runAction(context, () => widget.orgApi!.resetOverride(current!['id'] as String), done: 'Override removed');
    await load();
  }

  /// Content of [ch] the designer would open with (draft, else latest published), for the channel cards.
  Json? _contentOf(String ch) {
    if (ch == channel) return content();
    final rows = versions.where((v) => v['channel'] == ch && v['status'] != 'RETIRED').toList()
      ..sort((a, b) => (b['version'] as int).compareTo(a['version'] as int));
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first['content'] as Map? ?? {});
  }

  String _stateOf(String ch) {
    if (widget.isOverride) return ch == channel ? (current != null ? 'Org override' : 'Platform') : '';
    final rows = versions.where((v) => v['channel'] == ch).toList();
    if (rows.any((v) => v['status'] == 'DRAFT')) return 'Draft';
    final pub = rows.where((v) => v['status'] == 'PUBLISHED').map((v) => v['version'] as int).toList()..sort();
    return pub.isEmpty ? 'Not set' : 'v${pub.last} published';
  }

  void _select(String ch) {
    if (ch == channel) return;
    channel = ch;
    load();
  }

  static const _label = TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Color(0xFF64748B));

  Widget _header(BuildContext context, List<String> vars) {
    final theme = Theme.of(context);
    final code = '${widget.template['code'] ?? 'Template'}';
    final active = [for (final c in kChannels) if ((_contentOf(c) ?? {}).isNotEmpty) c];
    final (badge, badgeColor, explain) = widget.isOverride
        ? current != null
            ? ('ORG OVERRIDE', const Color(0xFFCA8A04), 'This organization has its own wording on v${widget.baseVersion}. Only changed fields are stored.')
            : ('PLATFORM v${widget.baseVersion}', const Color(0xFF16A34A), 'Showing the platform template. Publish an override to change it for this organization only.')
        : versions.any((v) => v['status'] == 'DRAFT')
            ? ('DRAFT', const Color(0xFF1A56DB), 'Editing the platform template. Saving updates the draft; publishing sets the version new organizations start on.')
            : ('PLATFORM TEMPLATE', const Color(0xFF16A34A), 'Editing the platform template. Saving updates the draft; publishing sets the version new organizations start on.');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.description_outlined, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text('$code  ·  Notification template', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
          _Badge(badge, badgeColor, key: const ValueKey('designer-badge')),
        ]),
        const SizedBox(height: 6),
        Text(explain, style: theme.textTheme.bodySmall?.copyWith(color: badgeColor)),
        const SizedBox(height: 10),
        Row(children: [
          Text('Active channels:', style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              if (active.isEmpty) Text('None yet', style: theme.textTheme.bodySmall),
              for (final c in active) _Badge(chLabel(c).toUpperCase(), channelStyles[c]!.color),
            ]),
          ),
          Text('${vars.length} variables available', style: theme.textTheme.bodySmall),
        ]),
      ]),
    );
  }

  Widget _channelCard(BuildContext context, String ch) {
    final st = channelStyles[ch]!, on = ch == channel, hasContent = (_contentOf(ch) ?? {}).isNotEmpty;
    final theme = Theme.of(context);
    final state = _stateOf(ch);
    return Expanded(
      child: InkWell(
        key: ValueKey('channel-$ch'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => _select(ch),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          decoration: BoxDecoration(
            color: on ? st.color.withAlpha(24) : theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? st.color : theme.colorScheme.outlineVariant, width: on ? 1.6 : 1.1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(st.icon, size: 16, color: on ? st.color : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(child: Text(chLabel(ch), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700))),
              if (state.isNotEmpty) Text(state, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Icon(hasContent ? Icons.check_circle_outline : Icons.radio_button_unchecked,
                  size: 12, color: hasContent ? const Color(0xFF16A34A) : theme.colorScheme.outline),
              const SizedBox(width: 4),
              Text(hasContent ? 'Content set' : 'No content',
                  style: TextStyle(fontSize: 10.5, color: hasContent ? const Color(0xFF16A34A) : theme.colorScheme.outline)),
              const Spacer(),
              Icon(on ? Icons.edit : Icons.edit_outlined, size: 13, color: on ? st.color : theme.colorScheme.outline),
              const SizedBox(width: 2),
              Text(on ? 'Editing' : 'Edit', style: TextStyle(fontSize: 11, color: on ? st.color : theme.colorScheme.outline)),
            ]),
          ]),
        ),
      ),
    );
  }

  /// Override mode: the platform's wording for this channel, read-only, so the two are never confused.
  Widget _platformWording(BuildContext context) {
    final theme = Theme.of(context);
    final fields = [for (final f in channelFields[channel]!) if ((base[f] ?? '').toString().isNotEmpty) f];
    return Container(
      key: const ValueKey('platform-wording'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(110),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.lock_outline, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('PLATFORM WORDING · v${widget.baseVersion} · read-only', style: _label),
        ]),
        const SizedBox(height: 6),
        if (fields.isEmpty) Text('The platform template has no ${chLabel(channel)} wording.', style: theme.textTheme.bodySmall),
        for (final f in fields)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '${_fieldLabel(f)}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: '${base[f]}'),
            ]), style: theme.textTheme.bodySmall),
          ),
      ]),
    );
  }

  String _fieldLabel(String f) => const {
        'title': 'Title',
        'body': 'Message body',
        'route': 'Open screen (route)',
        'msg91_template_id': 'MSG91 template ID',
        'dlt_template_id': 'DLT template ID',
        'template_name': 'WhatsApp template name (approved in Meta)',
        'language': 'Language (e.g. en)',
        'params': 'Template parameters (JSON list, in order)',
      }[f] ??
      f;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final st = channelStyles[channel]!;
    Map<String, dynamic> data;
    String? sampleError;
    try {
      data = Map<String, dynamic>.from(jsonDecode(sample.text) as Map);
    } catch (_) {
      data = {};
      sampleError = 'Sample data is not valid JSON';
    }
    final fields = channelFields[channel]!;
    String text(String f) => fields.contains(f) ? controllers[f]?.text ?? '' : '';
    final previewTitle = renderPreview(text('title'), data);
    final previewBody = renderPreview(fields.contains('body') ? text('body') : text('params'), data);
    final missing = {...previewTitle.missing, ...previewBody.missing};
    final used = <String>{for (final c in kChannels) ...templatePaths(jsonEncode(_contentOf(c) ?? {}))};
    final vars = <String>{
      if (variables.isNotEmpty) ...variables.map((v) => v['path'] as String) else ...['recipient.name', 'data.amount', 'data.reference', 'data.flat'],
      ...used,
    }.toList();

    final editor = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: st.color.withAlpha(90)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(st.icon, color: st.color, size: 18),
          const SizedBox(width: 8),
          Text('${chLabel(channel)} content', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          if (widget.isOverride && current != null) ...[
            const SizedBox(width: 8),
            statusChip('Override v${current!['version']} published', color: Colors.orange),
          ],
        ]),
        const Divider(height: 20),
        if (widget.isOverride) ...[
          _platformWording(context),
          const SizedBox(height: 12),
          const Text("THIS ORGANIZATION'S WORDING", style: _label),
          const SizedBox(height: 8),
        ],
        for (final f in channelFields[channel]!) ...[
          if (f == 'body' || f == 'params') ...[
            Text(f == 'body' ? 'BODY' : 'PARAMETERS', style: _label),
            const SizedBox(height: 6),
          ],
          Focus(
            onFocusChange: (has) {
              if (has) focused = controllers[f];
            },
            child: TextField(
              key: ValueKey('field-$f'),
              controller: controllers[f],
              maxLines: f == 'body' || f == 'params' ? 6 : 1,
              decoration: f == 'body' || f == 'params'
                  ? InputDecoration(
                      hintText: f == 'body' ? 'Message body…' : '["{{recipient.name}}", "{{data.amount}}"]',
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: st.color, width: 1.6)),
                    )
                  : InputDecoration(
                      labelText: _fieldLabel(f),
                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: st.color, width: 1.6)),
                    ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (channel == 'SMS')
          Text(smsInfo(previewBody.text), key: const ValueKey('sms-info'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        const Text('INSERT VARIABLE', style: _label),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final v in vars)
            ActionChip(
              key: ValueKey('var-$v'),
              label: Text('{{$v}}', style: TextStyle(color: st.color, fontSize: 12)),
              side: BorderSide(color: st.color.withAlpha(90)),
              visualDensity: VisualDensity.compact,
              onPressed: () => insertVariable(v),
            ),
        ]),
        const SizedBox(height: 16),
        Row(children: widget.isOverride
            ? [
                if (current != null) ...[
                  OutlinedButton.icon(onPressed: busy ? null : resetOverride, icon: const Icon(Icons.restore, size: 16), label: const Text('Reset to platform')),
                  const SizedBox(width: 8),
                ],
                FilledButton.icon(onPressed: busy ? null : publishOverride, icon: const Icon(Icons.publish, size: 16), label: const Text('Publish override')),
              ]
            : [
                OutlinedButton.icon(onPressed: busy ? null : saveDraft, icon: const Icon(Icons.save_outlined, size: 16), label: const Text('Save draft')),
                const SizedBox(width: 8),
                FilledButton.icon(onPressed: busy ? null : publish, icon: const Icon(Icons.publish, size: 16), label: const Text('Publish')),
              ]),
      ]),
    );

    final preview = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('LIVE PREVIEW', style: _label),
      const SizedBox(height: 8),
      Center(
        child: ChannelPreview(
            channel: channel,
            title: previewTitle.text,
            body: previewBody.text,
            extra: channel == 'WHATSAPP' ? text('template_name') : text('route')),
      ),
      const SizedBox(height: 8),
      if (sampleError != null) Text(sampleError, style: const TextStyle(color: Colors.red)),
      if (missing.isEmpty && sampleError == null)
        const Row(children: [
          Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF16A34A)),
          SizedBox(width: 4),
          Text('All variables resolve', key: ValueKey('vars-ok'), style: TextStyle(color: Color(0xFF16A34A))),
        ]),
      if (missing.isNotEmpty) Text('Missing: ${missing.join(', ')}', key: const ValueKey('vars-missing'), style: const TextStyle(color: Colors.red)),
      const SizedBox(height: 12),
      ExpansionTile(
        key: const ValueKey('sample-tile'),
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: sampleError != null,
        title: const Text('SAMPLE DATA', style: _label),
        subtitle: const Text('Edit to try other values; nothing here is saved.'),
        children: [
          TextField(
              key: const ValueKey('sample'),
              controller: sample,
              maxLines: 8,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
              onChanged: (_) => setState(() {})),
        ],
      ),
    ]);

    return ListView(padding: const EdgeInsets.all(16), children: [
      _header(context, vars),
      const SizedBox(height: 14),
      const Text('CHANNELS', style: _label),
      const SizedBox(height: 8),
      Row(children: [
        for (final c in kChannels) ...[
          _channelCard(context, c),
          if (c != kChannels.last) const SizedBox(width: 8),
        ],
      ]),
      const SizedBox(height: 16),
      LayoutBuilder(
          builder: (context, c) => c.maxWidth > 820
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 3, child: editor),
                  const SizedBox(width: 20),
                  Expanded(flex: 2, child: preview),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [editor, const SizedBox(height: 16), preview])),
    ]);
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge(this.label, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: color.withAlpha(160)),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
      );
}

/// A phone-style preview of one channel's message: an in-app notification card, an SMS bubble,
/// a WhatsApp chat bubble or a lock-screen push banner.
class ChannelPreview extends StatelessWidget {
  final String channel, title, body, extra;
  const ChannelPreview({super.key, required this.channel, required this.title, required this.body, this.extra = ''});

  @override
  Widget build(BuildContext context) {
    final (bg, bar, barText) = switch (channel) {
      'WHATSAPP' => (const Color(0xFFECE5DD), const Color(0xFF075E54), 'Society office'),
      'SMS' => (Colors.white, const Color(0xFFF1F3F4), 'AX-SOCIETY'),
      'PUSH' => (const Color(0xFF1F2A44), Colors.transparent, ''),
      _ => (const Color(0xFFF5F6FA), const Color(0xFF1A56DB), 'Notifications'),
    };
    final titleW = title.isEmpty ? null : Text(title, key: const ValueKey('preview-title'), style: const TextStyle(fontWeight: FontWeight.w700));
    final bodyW = Text(body, key: const ValueKey('preview-body'));
    Widget message = switch (channel) {
      'SMS' => Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: const BoxDecoration(
                color: Color(0xFFE9E9EB),
                borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16), bottomRight: Radius.circular(16), bottomLeft: Radius.circular(4))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [if (titleW != null) titleW, bodyW]),
          )),
      'WHATSAPP' => Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 2, offset: Offset(0, 1))]),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (extra.isNotEmpty) Text(extra, style: const TextStyle(fontSize: 11, color: Color(0xFF128C7E), fontWeight: FontWeight.w600)),
              if (titleW != null) titleW,
              bodyW,
              const Align(alignment: Alignment.centerRight, child: Text('10:24 ✓✓', style: TextStyle(fontSize: 10, color: Color(0xFF34B7F1)))),
            ]),
          )),
      'PUSH' => Container(
          margin: const EdgeInsets.fromLTRB(10, 28, 10, 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.white.withAlpha(235), borderRadius: BorderRadius.circular(14)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 28, height: 28, decoration: BoxDecoration(color: const Color(0xFF1A56DB), borderRadius: BorderRadius.circular(7)), child: const Icon(Icons.apartment, color: Colors.white, size: 16)),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('SOCIETY · now', style: TextStyle(fontSize: 10, color: Colors.black54)),
              if (titleW != null) titleW,
              bodyW,
              if (extra.isNotEmpty) Text('Opens $extra', style: const TextStyle(fontSize: 10, color: Colors.black45)),
            ])),
          ]),
        ),
      _ => Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE2E8F0))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const CircleAvatar(radius: 14, backgroundColor: Color(0xFFEDE7F6), child: Icon(Icons.notifications, size: 16, color: Color(0xFF9C4DCC))),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (titleW != null) titleW,
              bodyW,
              const SizedBox(height: 4),
              const Text('just now', style: TextStyle(fontSize: 10, color: Colors.black45)),
            ])),
            Container(width: 8, height: 8, margin: const EdgeInsets.only(top: 4), decoration: const BoxDecoration(color: Color(0xFF1A56DB), shape: BoxShape.circle)),
          ]),
        ),
    };
    return Container(
      key: ValueKey('preview-$channel'),
      width: 320,
      constraints: const BoxConstraints(minHeight: 260),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF111827), width: 6),
      ),
      clipBehavior: Clip.antiAlias,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: channel == 'PUSH' ? Colors.black87 : const Color(0xFF111827), fontSize: 13),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          if (barText.isNotEmpty)
            Container(
              color: bar,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text(barText, style: TextStyle(color: bar == const Color(0xFFF1F3F4) ? Colors.black87 : Colors.white, fontWeight: FontWeight.w600)),
            ),
          if (channel == 'PUSH') const Padding(padding: EdgeInsets.only(top: 18), child: Center(child: Text('10:24', style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w300)))),
          message,
        ]),
      ),
    );
  }
}
