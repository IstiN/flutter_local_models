import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class StudioSvgIcon extends StatelessWidget {
  const StudioSvgIcon(this.name, {super.key, this.size = 24, this.opacity = 1});

  final String name;
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: SvgPicture.asset(
        'assets/icons/$name.svg',
        width: size,
        height: size,
      ),
    );
  }
}
