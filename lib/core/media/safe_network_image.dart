import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'image_loader.dart';

class SafeNetworkImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final Widget placeholder;

  const SafeNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.contain,
    this.placeholder = const SizedBox.shrink(),
  });

  @override
  State<SafeNetworkImage> createState() => _SafeNetworkImageState();
}

class _SafeNetworkImageState extends State<SafeNetworkImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SafeNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final result = await loadImageWithRetry(widget.url);
    if (mounted && result.isSuccess) {
      setState(() {
        _bytes = Uint8List.fromList(result.bytes!);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: widget.fit);
    }
    return widget.placeholder;
  }
}
