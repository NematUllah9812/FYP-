import 'package:flutter/material.dart';
import 'api/client.dart';
import 'state/app_state.dart';
import 'tracker/tracker_bridge.dart';
import 'theme.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final api = TerrastepApi();
  final state = AppState(api, TrackerBridge());
  state.bootstrap();
  runApp(TerrastepApp(state: state));
}

class TerrastepApp extends StatelessWidget {
  const TerrastepApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return MaterialApp(
          title: 'Terrastep',
          debugShowCheckedModeBanner: false,
          theme: TSTheme.light(),
          darkTheme: TSTheme.dark(),
          themeMode:
              ThemeMode.system, // respect system preference (Section 5/7)
          home: !state.ready
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : state.signedIn
                  ? HomeShell(state: state)
                  : OnboardingScreen(state: state),
        );
      },
    );
  }
}
