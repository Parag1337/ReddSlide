import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/feed/presentation/home_screen.dart';
import '../../features/feed/presentation/subreddit_screen.dart';
import '../../features/search/presentation/search_screen.dart';
import '../../features/slideshow/presentation/slideshow_screen.dart';
import '../../features/slideshow/domain/slideshow_source.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.toString(), child: child),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: const HomeScreen(),
            ),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: const SearchScreen(),
            ),
          ),
          GoRoute(
            path: '/groups',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: const GroupsPlaceholderScreen(),
            ),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: const SettingsScreen(),
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/subreddit/:name',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final name = state.pathParameters['name'] ?? '';
          return SubredditScreen(subredditName: name);
        },
      ),
      GoRoute(
        path: '/slideshow',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          final extra = state.extra;
          SlideshowSource source;
          int startIndex = 0;
          if (extra is SlideshowRouteExtra) {
            source = extra.source;
            startIndex = extra.startIndex;
          } else if (extra is SlideshowSource) {
            source = extra;
          } else {
            source = extra as SlideshowSource? ?? const GlobalFeedSource();
          }
          return CustomTransitionPage(
            key: state.pageKey,
            fullscreenDialog: true,
            child: SlideshowScreen(
              source: source,
              startIndex: startIndex,
            ),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              return FadeTransition(opacity: animation, child: child);
            },
          );
        },
      ),
    ],
  );
});

class AppShell extends ConsumerWidget {
  final String location;
  final Widget child;

  const AppShell({super.key, required this.location, required this.child});

  int _indexFromLocation() {
    if (location.startsWith('/search')) return 1;
    if (location.startsWith('/groups')) return 2;
    if (location.startsWith('/settings')) return 3;
    return 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentIndex = _indexFromLocation();

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (index) {
          switch (index) {
            case 0:
              context.go('/');
              break;
            case 1:
              context.go('/search');
              break;
            case 2:
              context.go('/groups');
              break;
            case 3:
              context.go('/settings');
              break;
          }
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(
            icon: Badge(label: Text('Soon'), child: Icon(Icons.folder_outlined)),
            selectedIcon: Badge(label: Text('Soon'), child: Icon(Icons.folder)),
            label: 'Groups',
          ),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

class GroupsPlaceholderScreen extends StatelessWidget {
  const GroupsPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Groups')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_special, size: 80, color: theme.colorScheme.primary.withValues(alpha: 0.5)),
              const SizedBox(height: 24),
              Text('Groups', style: theme.textTheme.displayMedium),
              const SizedBox(height: 16),
              Text(
                'Create themed collections of subreddits with custom filters. Coming in a future update.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
