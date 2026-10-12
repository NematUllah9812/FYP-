import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Onboarding — Blueprint Section 5. Explain before collecting; request
/// permissions only at the point of use; everything optional stays optional.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.state});
  final AppState state;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  bool _busy = false;
  String? _error;

  final _email = TextEditingController();
  final _password = TextEditingController();
  final _nickname = TextEditingController();
  final _weight = TextEditingController();

  String _intent = 'fitness';
  int _goalWalks = 3;
  bool _competitionOptIn = false;
  bool _hasAccount = false;

  Future<void> _submitAccount() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_hasAccount) {
        await widget.state.logIn(_email.text.trim(), _password.text);
      } else {
        await widget.state
            .signUp(_email.text.trim(), _password.text, _nickname.text.trim());
      }
      setState(() => _step = 2);
    } catch (e) {
      setState(() => _error =
          'Account step failed. Check the details and your connection.');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    // Save optional profile choices; all are editable later (Section 5).
    final fields = <String, dynamic>{
      'weekly_goal_walks': _goalWalks,
      'competition_opt_in': _competitionOptIn ? 1 : 0,
      if (_weight.text.trim().isNotEmpty)
        'weight_kg': double.tryParse(_weight.text.trim()),
    };
    try {
      await widget.state.api.patchProfile(fields);
    } catch (_) {
      // Non-fatal: preferences can be set later in Settings.
    }
    if (mounted) setState(() => _step = 5);
  }

  Future<void> _requestFirstWalkPermissions() async {
    // Point-of-use permission requests (Section 5): foreground location
    // and physical activity, each explained on the previous step.
    await Permission.location.request();
    await Permission.activityRecognition.request();
    await Permission.notification.request();
    if (mounted) setState(() => _step = 6);
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      _welcome(),
      _account(),
      _intentStep(),
      _goalStep(),
      _visibilityStep(),
      _firstWalkStep(),
      _readyStep(),
    ];
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(TS.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: (_step + 1) / steps.length),
              const SizedBox(height: TS.s3),
              Expanded(child: SingleChildScrollView(child: steps[_step])),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: TS.s2),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _welcome() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Walk your neighborhood.\nBuild your kingdom.',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: TS.s2),
          const Text(
              'Terrastep turns ordinary walks into a friendly local territory game. '
              'Your fitness history is private by default. Territory is earned only '
              'from verified outdoor walking.'),
          const SizedBox(height: TS.s4),
          FilledButton(
            onPressed: () => setState(() => _step = 1),
            child: const Text('Get started'),
          ),
          const SizedBox(height: TS.s1),
          TextButton(
            onPressed: () => setState(() {
              _hasAccount = true;
              _step = 1;
            }),
            child: const Text('I already have an account'),
          ),
        ],
      );

  Widget _account() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_hasAccount ? 'Welcome back' : 'Create your account',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: TS.s2),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: TS.s1),
          TextField(
            controller: _password,
            obscureText: true,
            decoration:
                const InputDecoration(labelText: 'Password (8+ characters)'),
          ),
          if (!_hasAccount) ...[
            const SizedBox(height: TS.s1),
            TextField(
              controller: _nickname,
              decoration: const InputDecoration(
                  labelText: 'Nickname (public game name, 2–24 characters)'),
            ),
          ],
          const SizedBox(height: TS.s3),
          FilledButton(
            onPressed: _busy ? null : _submitAccount,
            child: Text(
                _busy ? 'Please wait…' : (_hasAccount ? 'Log in' : 'Sign up')),
          ),
        ],
      );

  Widget _intentStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What brings you here? (optional)',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: TS.s2),
          RadioGroup<String>(
            groupValue: _intent,
            onChanged: (v) => setState(() => _intent = v ?? _intent),
            child: Column(
              children: [
                for (final (value, label) in [
                  ('fitness', 'Fitness — walk more, feel better'),
                  ('exploration', 'Exploration — discover my area'),
                  ('competition', 'Friendly competition — claim territory'),
                ])
                  RadioListTile<String>(
                    value: value,
                    title: Text(label),
                  ),
              ],
            ),
          ),
          const SizedBox(height: TS.s2),
          FilledButton(
              onPressed: () => setState(() => _step = 3),
              child: const Text('Continue')),
          TextButton(
              onPressed: () => setState(() => _step = 3),
              child: const Text('Skip')),
        ],
      );

  Widget _goalStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('A manageable weekly plan',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: TS.s2),
          const Text('Pick what feels comfortable. You can change it any time, '
              'and rest weeks still count when you meet your own plan.'),
          const SizedBox(height: TS.s2),
          Wrap(
            spacing: TS.s1,
            children: [
              for (final n in [2, 3, 4, 5])
                ChoiceChip(
                  label: Text('$n walks / week'),
                  selected: _goalWalks == n,
                  onSelected: (_) => setState(() => _goalWalks = n),
                ),
            ],
          ),
          const SizedBox(height: TS.s2),
          TextField(
            controller: _weight,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Weight in kg (optional — only for calorie estimates)',
              helperText: 'Estimates are hidden completely if you skip this.',
            ),
          ),
          const SizedBox(height: TS.s3),
          FilledButton(
              onPressed: () => setState(() => _step = 4),
              child: const Text('Continue')),
        ],
      );

  Widget _visibilityStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your privacy, your choice',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: TS.s2),
          const Text('Your walks, weight and calories are always private. '
              'Public competition is separate and optional: other players can '
              'see your nickname and which area you hold — never your routes, '
              'times, or live location.'),
          const SizedBox(height: TS.s2),
          SwitchListTile(
            value: _competitionOptIn,
            onChanged: (v) => setState(() => _competitionOptIn = v),
            title: const Text('Join public competition'),
            subtitle:
                const Text('You can pause or leave at any time in Settings.'),
          ),
          const SizedBox(height: TS.s2),
          FilledButton(onPressed: _finish, child: const Text('Continue')),
        ],
      );

  Widget _firstWalkStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Before your first walk',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: TS.s2),
          const Text('When you tap Start, Terrastep asks for precise location '
              '(needed to award territory fairly) and motion access (step '
              'counting). Recording happens only while a walk is running, '
              'with a visible notification and a Stop button.\n\n'
              'If you decline, you can still browse your history — ranked '
              'walks need precise location.'),
          const SizedBox(height: TS.s3),
          FilledButton(
              onPressed: _requestFirstWalkPermissions,
              child: const Text('Understood')),
          TextButton(
              onPressed: () => setState(() => _step = 6),
              child: const Text('Decide later')),
        ],
      );

  Widget _readyStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("You're ready.",
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: TS.s2),
          const Text('Your first walk starts whenever you do.'),
          const SizedBox(height: TS.s4),
          FilledButton(
            onPressed: () {
              // AppState.signedIn is now true; MaterialApp rebuilds to shell.
              setState(() {});
            },
            child: const Text('Go to Terrastep'),
          ),
        ],
      );
}
