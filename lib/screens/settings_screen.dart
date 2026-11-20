import 'package:flutter/material.dart';
import 'package:grid_frontend/services/sharing_state_notifier.dart';
import 'package:grid_frontend/services/theme_controller.dart';
import 'package:grid_frontend/services/units_controller.dart';
import 'package:grid_frontend/widgets/grid/grid_mono.dart';

/// Settings tab: sharing, units, appearance, and app info — the pieces of the
/// original settings that still apply to the P2P app (no account/Matrix).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    SharingStateNotifier.instance.addListener(_onChanged);
    UnitsController.instance.addListener(_onChanged);
    ThemeController.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SharingStateNotifier.instance.removeListener(_onChanged);
    UnitsController.instance.removeListener(_onChanged);
    ThemeController.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final incognito = SharingStateNotifier.instance.userIncognito;
    final speedUnit = UnitsController.instance.speedUnit;
    final themeMode = ThemeController.instance.mode;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _sectionLabel(context, 'Sharing'),
          SwitchListTile(
            title: const Text('Pause location sharing'),
            subtitle: const Text('Go incognito — stop sharing your live location'),
            value: incognito,
            onChanged: (v) => SharingStateNotifier.instance.setUserIncognito(v),
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Units'),
          ListTile(
            title: const Text('Speed units'),
            subtitle: Text('Show contact speed as ${speedUnit.label}'),
            trailing: DropdownButton<SpeedUnit>(
              value: speedUnit,
              underline: const SizedBox.shrink(),
              items: SpeedUnit.values
                  .map((u) => DropdownMenuItem(value: u, child: Text(u.label)))
                  .toList(),
              onChanged: (u) {
                if (u != null) UnitsController.instance.setSpeedUnit(u);
              },
            ),
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Appearance'),
          ListTile(
            title: const Text('Theme'),
            subtitle: Text(_themeLabel(themeMode)),
            trailing: DropdownButton<ThemeMode>(
              value: themeMode,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
              ],
              onChanged: (m) {
                if (m != null) ThemeController.instance.setMode(m);
              },
            ),
          ),

          const SizedBox(height: 24),
          _sectionLabel(context, 'About'),
          const ListTile(
            title: Text('Grid'),
            subtitle: Text('Peer-to-peer location sharing over Veilid'),
          ),
          ListTile(
            title: const Text('Your address'),
            subtitle: const GridMono('Tap Contacts to view your QR',
                size: 10, uppercase: false),
            enabled: false,
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  String _themeLabel(ThemeMode m) => switch (m) {
        ThemeMode.dark => 'Dark',
        ThemeMode.light => 'Light',
        ThemeMode.system => 'System',
      };
}
