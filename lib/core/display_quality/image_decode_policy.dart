import 'package:flutter/material.dart';
import 'display_quality_mode.dart';

class DecodeSize {
  final int? width;
  final int? height;

  const DecodeSize({this.width, this.height});

  bool get isOriginal => width == null && height == null;
}

class ImageDecodePolicy {
  final DisplayQualityMode mode;
  final double screenWidth;
  final double screenHeight;
  final double pixelRatio;
  final double qualityMultiplier;

  const ImageDecodePolicy({
    required this.mode,
    required this.screenWidth,
    required this.screenHeight,
    required this.pixelRatio,
    this.qualityMultiplier = 1.0,
  });

  DecodeSize getDecodeSize() {
    switch (mode) {
      case DisplayQualityMode.smart:
      case DisplayQualityMode.auto:
        final w = (screenWidth * pixelRatio * qualityMultiplier).ceil();
        return DecodeSize(width: w);
      case DisplayQualityMode.original:
        return const DecodeSize();
    }
  }

  static ImageDecodePolicy fromContext({
    required BuildContext context,
    required DisplayQualityMode mode,
  }) {
    final mediaQuery = MediaQuery.of(context);
    return ImageDecodePolicy(
      mode: mode,
      screenWidth: mediaQuery.size.width,
      screenHeight: mediaQuery.size.height,
      pixelRatio: mediaQuery.devicePixelRatio,
    );
  }
}
