import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grid_frontend/services/location/home_geofence_service.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/sharing_state_notifier.dart';
import 'package:grid_frontend/services/theme_controller.dart';
import 'package:grid_frontend/services/units_controller.dart';
import 'package:grid_frontend/widgets/grid/grid_mono.dart';

/// Settings tab: sharing, units, appearance, home location, notifications, and
/// app info — the pieces of the original settings that still apply to the
/// P2P app (no account/Matrix).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _homeLocation; // "lat,lng"
  double _homeRadius = 25;
  bool _autoPauseAtHome = false;
  bool _notifications = true;

  @override
  void initState() {
    super.initState();
    _loadHome();
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

  Future<void> _loadHome() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _homeLocation = prefs.getString('home_location');
      _homeRadius = prefs.getDouble('home_radius') ?? 25;
      _autoPauseAtHome = prefs.getBool('auto_pause_at_home_enabled') ?? false;
      _notifications = prefs.getBool('notifications_enabled') ?? true;
    });
  }

  Future<void> _setHomeToCurrent() async {
    final me = LocationManager.instance.currentLatLng;
    if (me == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No location fix yet — move a little and retry.')),
        );
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'home_location', '${me.latitude},${me.longitude}');
    await prefs.setDouble('home_radius', _homeRadius);
    await _loadHome();
    await HomeGeofenceService.instance.syncFromPrefs();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Home location set to your current position')),
      );
    }
  }

  Future<void> _clearHome() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('home_location');
    await prefs.remove('home_radius');
    await _loadHome();
    await HomeGeofenceService.instance.syncFromPrefs();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Home location cleared')),
      );
    }
  }

  Future<void> _setPref(String key, Object? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool(key, value);
    if (value is double) await prefs.setDouble(key, value);
  }

  @override
  Widget build(BuildContext context) {
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
          _sectionLabel(context, 'Home'),
          ListTile(
            title: const Text('Home location'),
            subtitle: _homeLocation == null
                ? const Text('Not set')
                : GridMono(_homeLocation!, size: 10, uppercase: false),
            leading: const Icon(Icons.home_outlined),
          ),
          ListTile(
            title: const Text('Set home to current position'),
            leading: const Icon(Icons.my_location),
            onTap: _setHomeToCurrent,
          ),
          ListTile(
            title: const Text('Clear home location'),
            leading: const Icon(Icons.close),
            enabled: _homeLocation != null,
            onTap: _clearHome,
          ),
          SwitchListTile(
            title: const Text('Auto-pause at home'),
            subtitle: const Text('Pause sharing automatically when you arrive home'),
            value: _autoPauseAtHome,
            onChanged: (v) {
              setState(() => _autoPauseAtHome = v);
              _setPref('auto_pause_at_home_enabled', v);
              HomeGeofenceService.instance.syncFromPrefs();
            },
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Notifications'),
          SwitchListTile(
            title: const Text('Location update notifications'),
            subtitle: const Text('Notify when a contact shares a new location'),
            value: _notifications,
            onChanged: (v) {
              setState(() => _notifications = v);
              _setPref('notifications_enabled', v);
            },
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
          const ListTile(
            title: Text('Your address'),
            subtitle: GridMono('View it in the Contacts tab', size: 10, uppercase: false),
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
