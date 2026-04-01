import 'dart:async';

import 'package:flutter/material.dart';

import 'app_version.dart';

/// Full-screen launch splash shown briefly before the home page.
///
/// Auto-advances to [nextPage] after [_kDisplayDuration] via
/// [Navigator.pushReplacement], so the back button never returns here.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.nextPage});

  /// The widget to show after the splash completes.
  final Widget nextPage;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _kDisplayDuration = Duration(milliseconds: 1400);
  static const Duration _kFadeDuration = Duration(milliseconds: 400);

  late final AnimationController _fade;
  late final Animation<double> _opacity;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: _kFadeDuration);
    _opacity = CurvedAnimation(parent: _fade, curve: Curves.easeIn);
    _fade.forward();

    _timer = Timer(_kDisplayDuration, _advance);
  }

  void _advance() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, a, b) => widget.nextPage,
        transitionsBuilder: (_, animation, b, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: const Scaffold(
        backgroundColor: Color(0xFF1E1E1E),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'FileSteward',
                style: TextStyle(
                  color: Color(0xFFCCCCCC),
                  fontSize: 36,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 2,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'v$kAppVersion',
                style: TextStyle(
                  color: Color(0xFF858585),
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
