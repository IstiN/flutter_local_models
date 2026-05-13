import 'package:flutter/material.dart';

import 'studio_svg_icon.dart';

class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({super.key});

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
    )..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFFC8A7FF), Color(0xFF7AD7FF)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFC8A7FF).withValues(alpha: 0.28),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Center(child: StudioSvgIcon('sparkle', size: 18)),
            ),
            const SizedBox(width: 12),
            Text(
              'Thinking',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
            ...List<Widget>.generate(3, (index) {
              final phase = (controller.value + index * 0.18) % 1.0;
              final opacity = 0.35 + 0.65 * (1 - (phase - 0.5).abs() * 2);
              final scale = 0.72 + 0.36 * opacity;
              return Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(
                        0xFFC8A7FF,
                      ).withValues(alpha: opacity.clamp(0.35, 1.0)),
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
