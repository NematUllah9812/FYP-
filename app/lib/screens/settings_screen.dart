import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../state/app_state.dart';

/// Settings — Blueprint Section 6 supporting screens:
/// account, units/language, appearance, permissions, notifications,
/// visibility & exclusions, blocked/reporting, export & deletion, help,
/// legal, licenses/attribution, app version, diagnostics.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  Future<void> _toggleCompetition(bool value) async {
    setState(() => _busy = true);
    try {
      await widget.state.api
          .patchProfile({'competition_opt_in': value ? 1 : 0});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(value
                ? 'You are visible in public competition.'
                : 'Competition paused — your fitness history is unaffected.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not save. Try again when online.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addExclusionHere() async {
    final fix = widget.state.live.lastFix;
    if (fix == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No current location yet — start from the Start tab '
              'so we know where "here" is.')));
      return;
    }
    try {
      final out = await widget.state.api.addExclusion(fix.lat, fix.lng);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Protected area saved (${out['excluded_cells']} cells). '
                'These cells can no longer be claimed by you, and past links are removed.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not save the protected area.')));
      }
    }
  }

  Future<void> _export() async {
    try {
      final data = await widget.state.api.exportData();
      await Clipboard.setData(ClipboardData(
          text: const JsonEncoder.withIndent('  ').convert(data)));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Your data export was copied to the clipboard as JSON.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Export failed — check connection.')));
      }
    }
  }

  Future<void> _deleteAccount() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete account and data?'),
        content: const Text(
            'This permanently deletes your account, fitness history and '
            'territory identity. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete everything')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await widget.state.api.deleteAccount();
      await widget.state.signOut();
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Deletion failed — check connection.')));
      }
    }
  }

  Future<void> _reportUnsafe() async {
    final fix = widget.state.live.lastFix;
    try {
      await widget.state.api.report({
        'category': 'unsafe_cell',
        'detail': fix == null
            ? 'Reported from settings (no current fix)'
            : 'Reported near current location',
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Report sent. Thank you — a moderator will review it.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Report failed — check connection.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            title: Text('Visibility & competition'),
            subtitle:
                Text('Fitness is always private. Competition is separate.'),
          ),
          SwitchListTile(
            title: const Text('Public competition'),
            subtitle: const Text(
                'Others see your nickname and held areas — never routes or times.'),
            value:
                true, // server truth is fetched on the profile screen in production polish
            onChanged: _busy ? null : _toggleCompetition,
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Add a protected area here'),
            subtitle: const Text(
                'Cells around your current location become ineligible for your ranked play.'),
            onTap: _addExclusionHere,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Report an unsafe place'),
            subtitle: const Text('Tell moderators about a dangerous area.'),
            onTap: _reportUnsafe,
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Export my data'),
            subtitle: const Text(
                'Copies your profile, sessions and contributions as JSON.'),
            onTap: _export,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Privacy, terms & community rules'),
            subtitle: const Text(
                'How location evidence is used, stored for 72 hours, and deleted.'),
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('The short version'),
                content: const SingleChildScrollView(
                  child: Text('• Fitness history is private by default.\n'
                      '• Raw verification evidence is kept for 72 hours, then deleted.\n'
                      '• Public territory appears at least 30 minutes after a walk.\n'
                      '• No live locations, routes, or exact times are ever public.\n'
                      '• Play only in public, safe places. Territory is a game '
                      'identity and creates no property rights.\n\n'
                      'Full legal documents ship with the pilot release.'),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close')),
                ],
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About & licenses'),
            subtitle: const Text(
                'Terrastep 0.1.0 · Map © OpenStreetMap contributors (dev tiles)'),
            onTap: () =>
                showLicensePage(context: context, applicationName: 'Terrastep'),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.delete_forever,
                color: Theme.of(context).colorScheme.error),
            title: Text('Delete account and data',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: _deleteAccount,
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              await widget.state.signOut();
              if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ],
      ),
    );
  }
}
