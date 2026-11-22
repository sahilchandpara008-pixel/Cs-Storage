import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/backend.dart';
import '../widgets/common.dart';
import '../widgets/poster_tile.dart';
import '../widgets/reload.dart';
import '../theme.dart';

/// Explore: every visible post from all channels, as a grid of media cards.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  static const tabs = [
    ('all', 'All'),
    ('latest', 'Latest'),
    ('popular', 'Popular'),
    ('most_watched', 'Most watched'),
  ];

  final _controller = TextEditingController();
  Timer? _debounce;
  bool searching = false;
  String query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _closeSearch() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      searching = false;
      query = '';
    });
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          flexibleSpace: const DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.barGradient),
            child: SizedBox.expand(),
          ),
          title: searching
              ? TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  onSubmitted: (v) {
                    _debounce?.cancel();
                    setState(() => query = v.trim());
                  },
                  style: const TextStyle(fontFamily: AppFonts.body, fontSize: 16),
                  decoration: const InputDecoration(
                    hintText: 'Search videos, shows, channels',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                )
              : Semantics(
                  header: true,
                  label: 'Explore',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset(
                          'assets/logo.png',
                          width: 34,
                          height: 34,
                          excludeFromSemantics: true,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const ExcludeSemantics(
                        child: Text(
                          'Flixvault',
                          style: TextStyle(
                            fontFamily: AppFonts.display,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          actions: searching
              ? [
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Close search',
                    onPressed: _closeSearch,
                  ),
                ]
              : [
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Search',
              onPressed: () => setState(() => searching = true),
            ),
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'About Explore',
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Explore'),
                  content: const Text(
                    'Discover posts from all channels. Tap a post to watch it.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
            ),
            const CrownButton(),
          ],
          bottom: searching
              ? null
              : PreferredSize(
            preferredSize: const Size.fromHeight(52),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                labelColor: AppColors.ink,
                unselectedLabelColor: const Color(0xFFD4D4D8),
                indicatorSize: TabBarIndicatorSize.tab,
                splashBorderRadius: BorderRadius.circular(999),
                indicator: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                labelStyle: const TextStyle(
                  fontFamily: AppFonts.body,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontFamily: AppFonts.body,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                tabs: [
                  for (var i = 0; i < tabs.length; i++)
                    Tab(
                      height: 38,
                      // Outline only on the tabs that aren't selected; the
                      // selected one is the solid orange indicator.
                      child: Builder(
                        builder: (context) {
                          final tc = DefaultTabController.of(context);
                          return AnimatedBuilder(
                            animation: tc,
                            builder: (_, child) => Container(
                              height: 38,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: tc.index == i
                                      ? AppColors.primary
                                      : AppColors.border,
                                ),
                              ),
                              child: child,
                            ),
                            child: Text(tabs[i].$2),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        // The tabs stay mounted (just hidden) while searching, so closing the
        // search brings back exactly what was on screen.
        body: Stack(
          fit: StackFit.expand,
          children: [
            Offstage(
              offstage: searching,
              child: TabBarView(
                children: [for (final t in tabs) _ExploreGrid(tab: t.$1)],
              ),
            ),
            if (searching)
              query.isEmpty
                  ? const EmptyState(
                      message: 'Search videos, shows and channels.',
                      icon: Icons.search_rounded,
                    )
                  : _SearchResults(key: ValueKey(query), query: query),
          ],
        ),
      ),
    );
  }
}

class _ExploreGrid extends StatefulWidget {
  final String tab;
  const _ExploreGrid({required this.tab});

  @override
  State<_ExploreGrid> createState() => _ExploreGridState();
}

class _ExploreGridState extends State<_ExploreGrid>
    with ContentReload, AutomaticKeepAliveClientMixin {
  List<Post>? posts;
  String? error;
  bool loadingMore = false;
  bool done = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Future<void> reload() async {
    try {
      final list = await Backend.explore(widget.tab);
      if (!mounted) return;
      setState(() {
        posts = list;
        error = null;
        done = list.length < 30;
      });
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    }
  }

  Future<void> _more() async {
    if (loadingMore || done || posts == null) return;
    loadingMore = true;
    try {
      final list = await Backend.explore(widget.tab, offset: posts!.length);
      if (mounted) {
        setState(() {
          posts = [...posts!, ...list];
          done = list.length < 30;
        });
      }
    } finally {
      loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (error != null && posts == null) {
      return ErrorRetry(message: error!, onRetry: reload);
    }
    if (posts == null) return const LoadingSkeleton();
    if (posts!.isEmpty) {
      return RefreshIndicator(
        onRefresh: reload,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            EmptyState(
              message: 'Nothing here yet.\nNew posts from channels will show up here.',
              icon: Icons.explore_outlined,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _more();
          return false;
        },
        child: LayoutBuilder(
          builder: (context, box) {
            // Every post as a portrait poster, title below.
            final cols = posterColumns(box.maxWidth);
            final list = posts!;
            return CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(
                  child: SectionTitle('Recommended for You'),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(posterPad, 0, posterPad, 24),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: posterGap,
                      mainAxisExtent: posterRowExtent(box.maxWidth),
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => PosterTile(post: list[i]),
                      childCount: list.length,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Results for a search: same cards as the Explore grid. The database applies
/// the normal visibility rules, so a user only ever finds what they could open.
class _SearchResults extends StatefulWidget {
  final String query;
  const _SearchResults({super.key, required this.query});

  @override
  State<_SearchResults> createState() => _SearchResultsState();
}

class _SearchResultsState extends State<_SearchResults> {
  List<Post>? posts;
  String? error;
  bool loadingMore = false;
  bool done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await Backend.explore('all', search: widget.query);
      if (!mounted) return;
      setState(() {
        posts = list;
        error = null;
        done = list.length < 30;
      });
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    }
  }

  Future<void> _more() async {
    if (loadingMore || done || posts == null) return;
    loadingMore = true;
    try {
      final list = await Backend.explore(
        'all',
        offset: posts!.length,
        search: widget.query,
      );
      if (mounted) {
        setState(() {
          posts = [...posts!, ...list];
          done = list.length < 30;
        });
      }
    } finally {
      loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null && posts == null) {
      return ErrorRetry(message: error!, onRetry: _load);
    }
    if (posts == null) return const LoadingSkeleton();
    if (posts!.isEmpty) {
      return EmptyState(
        message:
            'No videos found for "${widget.query}".\nTry another word, or look for a channel in the Channels tab.',
        icon: Icons.search_off_rounded,
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _more();
        return false;
      },
      child: LayoutBuilder(
        builder: (context, box) {
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(posterPad, 12, posterPad, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: posterColumns(box.maxWidth),
              mainAxisSpacing: 14,
              crossAxisSpacing: posterGap,
              mainAxisExtent: posterRowExtent(box.maxWidth),
            ),
            itemCount: posts!.length,
            itemBuilder: (context, i) => PosterTile(post: posts![i]),
          );
        },
      ),
    );
  }
}
