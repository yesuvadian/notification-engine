import 'package:flutter/material.dart';

import 'common.dart';
import 'platform_api.dart';

/// Values chosen in the Notifications step of the new-organization wizard.
class NotificationSetup extends ChangeNotifier {
  /// group -> channels. IN_APP is always included.
  final Map<String, Set<String>> preferences = {};
  int inboxRetentionDays = 90;
  String pushPrompt = 'after_first_notification';
  String? pushExplanation;

  bool has(String group, String channel) => channel == 'IN_APP' || (preferences[group]?.contains(channel) ?? false);

  void toggle(String group, String channel, bool on) {
    if (channel == 'IN_APP') return;
    final s = preferences.putIfAbsent(group, () => {});
    on ? s.add(channel) : s.remove(channel);
    notifyListeners();
  }

  bool get usesPush => preferences.values.any((s) => s.contains('PUSH'));

  Map<String, List<String>> preferencesJson(Iterable<String> groups) =>
      {for (final g in groups) g: ['IN_APP', ...kExternalChannels.where((c) => preferences[g]?.contains(c) ?? false)]};

  Json settingsJson() => {
        'inbox_retention_days': inboxRetentionDays,
        'push_prompt': usesPush ? pushPrompt : 'off',
        if (pushExplanation != null && pushExplanation!.trim().isNotEmpty) 'push_explanation': pushExplanation!.trim(),
      };

  void notify() => notifyListeners();
}

/// The Notifications step of the console's new-organization wizard: channels for each notification group
/// (only channels the product supports) and the member app settings. Locked once the organization is created.
class NotificationOrganizationStep extends StatelessWidget {
  final NotificationSetup setup;
  final List<String> groups;

  /// Channels the product supports (from its channel defaults).
  final Set<String> supported;

  const NotificationOrganizationStep({super.key, required this.setup, required this.groups, required this.supported});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: setup,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Channels for each notification group', style: Theme.of(context).textTheme.titleSmall),
          Text('Only channels the product supports are offered. What you choose is locked; later you can only add channels.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          if (groups.isEmpty) const Text('This product has not registered any events yet.'),
          if (groups.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(columns: [
                const DataColumn(label: Text('Group')),
                for (final c in kChannels) DataColumn(label: Text(chLabel(c))),
              ], rows: [
                for (final g in groups)
                  DataRow(cells: [
                    DataCell(Text(g)),
                    for (final c in kChannels)
                      DataCell(Checkbox(
                        key: ValueKey('pref-$g-$c'),
                        value: setup.has(g, c),
                        onChanged: c == 'IN_APP' || !supported.contains(c) ? null : (v) => setup.toggle(g, c, v == true),
                      )),
                  ]),
              ]),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 16, runSpacing: 8, children: [
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<int>(
                key: const ValueKey('retention'),
                initialValue: setup.inboxRetentionDays,
                decoration: const InputDecoration(labelText: 'Inbox keeps'),
                items: const [30, 90, 180, 365].map((d) => DropdownMenuItem(value: d, child: Text('$d days'))).toList(),
                onChanged: (v) {
                  setup.inboxRetentionDays = v ?? 90;
                  setup.notify();
                },
              ),
            ),
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('push-prompt'),
                isExpanded: true,
                initialValue: setup.pushPrompt,
                decoration: InputDecoration(labelText: 'Ask for push', helperText: setup.usesPush ? null : 'Push is not chosen for any group'),
                items: const [
                  DropdownMenuItem(value: 'after_first_notification', child: Text('After their first notification')),
                  DropdownMenuItem(value: 'first_login', child: Text('On first login')),
                ],
                onChanged: setup.usesPush
                    ? (v) {
                        setup.pushPrompt = v ?? 'after_first_notification';
                        setup.notify();
                      }
                    : null,
              ),
            ),
            SizedBox(
              width: 320,
              child: TextFormField(
                key: const ValueKey('push-text'),
                initialValue: setup.pushExplanation,
                enabled: setup.usesPush,
                decoration: const InputDecoration(labelText: 'Explanation shown before the system prompt'),
                onChanged: (v) => setup.pushExplanation = v,
              ),
            ),
          ]),
        ]),
      );
}

/// Provisions the organization in the notification engine with the wizard's choices (the module's create hook).
Future<Json> provisionNotifications(NotificationPlatformApi api,
        {required String productCode,
        required String organizationId,
        required String organizationName,
        required NotificationSetup setup,
        required List<String> groups}) =>
    api.createOrganization(
      productCode: productCode,
      organizationId: organizationId,
      organizationName: organizationName,
      preferences: setup.preferencesJson(groups),
      settings: setup.settingsJson(),
    );
