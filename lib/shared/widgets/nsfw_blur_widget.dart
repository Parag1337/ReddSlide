import 'dart:ui';
import 'package:flutter/material.dart';

class NsfwBlurWidget extends StatelessWidget {
  final Widget child;
  final bool isNsfw;
  final bool blurEnabled;

  const NsfwBlurWidget({
    super.key,
    required this.child,
    required this.isNsfw,
    this.blurEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!isNsfw || !blurEnabled) return child;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: child,
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'NSFW',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
