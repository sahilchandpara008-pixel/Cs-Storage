import 'package:flutter/material.dart';

import '../models.dart';
import '../screens/post_screen.dart';
import '../theme.dart';
import 'common.dart';

/// Columns for a poster grid: 3 on phones, more on wide screens.
int posterColumns(double width) => (width / 150).floor().clamp(3, 7);

/// Grid gaps and side padding used with [PosterTile].
const posterGap = 8.0;
const posterPad = 12.0;

/// Height of one grid row: the 2:3 poster plus the title (2 lines) and,
/// when shown, the channel name below it.
double posterRowExtent(double width, {bool showChannel = false}) {
  final cols = posterColumns(width);
  final cardW = (width - posterPad * 2 - posterGap * (cols - 1)) / cols;
  return cardW * 3 / 2 + 6 + 32 + (showChannel ? 17 : 0) + 4;
}

/// Netflix-style portrait poster: the video's thumbnail fills a 2:3 card
/// (length in the corner), the title (and channel) below it. Tapping opens
/// the post.
class PosterTile extends StatelessWidget {
  final Post post;
  final bool showChannel;
  const PosterTile({super.key, required this.post, this.showChannel = false});

  static const aspect = 2 / 3;

  @override
  Widget build(BuildContext context) {
    final cover = post.cover;
    final duration = cover?.durationS;
    return Semantics(
      label: post.title,
      button: true,
      child: PressScale(
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PostScreen(postId: post.id, initial: post),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: aspect,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        NetThumb(
                          url: cover?.thumbUrl,
                          fallback: cover?.isVideo == true
                              ? Icons.movie_outlined
                              : Icons.image_outlined,
                        ),
                        Positioned(
                          top: 5,
                          left: 5,
                          right: 5,
                          child: Row(
                            children: [
                              if (post.hasPremium)
                                const PremiumBadge(compact: true),
                              const Spacer(),
                              if (post.items.length > 1)
                                ThumbPill(
                                  '${post.items.length}',
                                  icon: Icons.collections_outlined,
                                )
                              else if (duration != null && duration > 0)
                                ThumbPill(formatDuration(duration)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                post.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
              if (showChannel)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    post.channelName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
