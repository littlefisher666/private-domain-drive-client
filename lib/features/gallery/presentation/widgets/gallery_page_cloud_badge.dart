import 'package:flutter/material.dart';

/// 云朵角标：表示原图尚未缓存到本机。
class GalleryPageCloudBadge extends StatelessWidget {
  const GalleryPageCloudBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: 0.55),
      ),
      child: const Icon(
        Icons.cloud_outlined,
        size: 13,
        color: Colors.white,
      ),
    );
  }
}
