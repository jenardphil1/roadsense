import 'package:flutter/material.dart';

/// The supplied RoadSense artwork, shared by mobile and web branding.
class RoadSenseBrand extends StatelessWidget {
  final double size;
  final bool showWordmark;
  final String? subtitle;
  final bool? isDarkOverride;

  const RoadSenseBrand({
    super.key,
    this.size = 36,
    this.showWordmark = false,
    this.subtitle,
    this.isDarkOverride,
  });

  @override
  Widget build(BuildContext context) {
    final dark =
        isDarkOverride ?? Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.asset(
            showWordmark
                ? (dark
                      ? 'assets/branding/full_logo_dark.png'
                      : 'assets/branding/full_logo.png')
                : 'assets/branding/icon.png',
            width: showWordmark ? size * 2.86 : size,
            height: size,
            fit: BoxFit.contain,
            semanticLabel: 'RoadSense AI logo',
          ),
        ),
        if (showWordmark && subtitle != null && subtitle!.isNotEmpty)
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: dark ? Colors.white70 : Colors.black54,
            ),
          ),
      ],
    );
  }
}
