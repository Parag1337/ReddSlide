import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/display_quality/display_quality_mode.dart';
import '../../../core/network/api_client.dart';
import '../providers/settings_provider.dart';
import '../domain/settings_model.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _isValidating = false;
  String? _healthResult;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    final theme = Theme.of(context);

    return settingsAsync.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
      data: (settings) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionHeader(title: 'Backend'),
            _buildBackendSection(settings, theme),
            const Divider(height: 32),
            _SectionHeader(title: 'Content'),
            _buildContentSection(settings, theme),
            const Divider(height: 32),
            _SectionHeader(title: 'Slideshow'),
            _buildSlideshowSection(settings, theme),
            const Divider(height: 32),
            _SectionHeader(title: 'Display'),
            _buildDisplaySection(settings, theme),
            const Divider(height: 32),
            _SectionHeader(title: 'Cache'),
            _buildCacheSection(theme),
            const Divider(height: 32),
            _SectionHeader(title: 'About'),
            _buildAboutSection(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildBackendSection(SettingsModel settings, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          ListTile(
            title: const Text('Backend URL'),
            subtitle: Text(
              settings.backendUrl.isEmpty ? 'Not configured' : settings.backendUrl,
              style: TextStyle(color: settings.backendUrl.isEmpty ? theme.colorScheme.error : null),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit URL',
              onPressed: () => _showUrlDialog(settings, theme),
            ),
          ),
          if (_healthResult != null)
            ListTile(
              dense: true,
              leading: Icon(
                Icons.circle,
                size: 10,
                color: _healthResult == 'Connected' ? Colors.green : Colors.red,
              ),
              title: Text(_healthResult!, style: theme.textTheme.bodySmall),
            ),
          if (_isValidating)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }

  Widget _buildContentSection(SettingsModel settings, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          ListTile(
            title: const Text('Subreddits'),
            subtitle: Text('${settings.subreddits.length} configured'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showSubredditManagement(settings, theme),
          ),
          SwitchListTile(
            title: const Text('Show NSFW content'),
            subtitle: const Text('Warning: may contain explicit content'),
            value: settings.nsfwEnabled,
            onChanged: (v) => ref.read(settingsProvider.notifier).toggleNsfw(v),
          ),
          ListTile(
            title: const Text('Default sort mode'),
            subtitle: Text(settings.defaultSortMode.toUpperCase()),
            trailing: DropdownButton<String>(
              value: settings.defaultSortMode,
              underline: const SizedBox(),
              items: ['hot', 'new', 'top'].map((m) => DropdownMenuItem(value: m, child: Text(m.toUpperCase()))).toList(),
              onChanged: (v) {
                if (v != null) ref.read(settingsProvider.notifier).setDefaultSortMode(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlideshowSection(SettingsModel settings, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          ListTile(
            title: const Text('Slideshow interval'),
            subtitle: Text('${settings.slideshowIntervalSeconds} seconds'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showIntervalDialog(settings, theme),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Display Quality', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ...DisplayQualityMode.values.where((m) => m != DisplayQualityMode.auto).map((mode) {
                  final selected = settings.displayQualityMode == mode;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => ref.read(settingsProvider.notifier).setDisplayQualityMode(mode),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2, right: 12),
                            child: Icon(
                              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                              size: 20,
                              color: selected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  mode.displayLabel,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                                    color: selected
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  mode.displayDescription,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDisplaySection(SettingsModel settings, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Theme', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('System')),
                ButtonSegment(value: 'light', label: Text('Light')),
                ButtonSegment(value: 'dark', label: Text('Dark')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (v) {
                ref.read(settingsProvider.notifier).setThemeMode(v.first);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCacheSection(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          const ListTile(
            title: Text('Status'),
            subtitle: Text('In-memory only (V1)'),
          ),
          ListTile(
            title: const Text('Clear session cache'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Clear cache?'),
                  content: const Text('This will clear all cached data.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                    FilledButton(onPressed: () { Navigator.pop(ctx); }, child: const Text('Clear')),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSection(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          const ListTile(
            title: Text('App version'),
            subtitle: Text('1.0.0+1'),
          ),
          ListTile(
            title: const Text('Backend version'),
            subtitle: Text(_healthResult ?? 'Unknown'),
          ),
        ],
      ),
    );
  }

  void _showUrlDialog(SettingsModel settings, ThemeData theme) {
    final controller = TextEditingController(text: settings.backendUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backend URL'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.100:8000',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final url = controller.text.trim();
              ref.read(settingsProvider.notifier).updateBackendUrl(url);
              Navigator.pop(ctx);
              _validateUrl(url);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _validateUrl(String url) async {
    if (url.isEmpty) return;
    setState(() { _isValidating = true; _healthResult = null; });
    try {
      final client = ApiClient(baseUrl: url);
      final result = await client.get('/api/health', fromJson: (json) => json);
      result.when(
        (_) => setState(() { _healthResult = 'Connected'; _isValidating = false; }),
        (e) => setState(() { _healthResult = 'Failed: $e'; _isValidating = false; }),
      );
    } catch (e) {
      setState(() { _healthResult = 'Failed: $e'; _isValidating = false; });
    }
  }

  void _showIntervalDialog(SettingsModel settings, ThemeData theme) {
    final intervals = [3, 5, 10, 15, 30];
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Slideshow interval'),
        children: intervals.map((interval) {
          return RadioListTile<int>(
            title: Text('$interval seconds'),
            value: interval,
            groupValue: settings.slideshowIntervalSeconds,
            onChanged: (v) {
              if (v != null) ref.read(settingsProvider.notifier).setSlideshowInterval(v);
              Navigator.pop(ctx);
            },
          );
        }).toList(),
      ),
    );
  }

  void _showSubredditManagement(SettingsModel settings, ThemeData theme) {
    final nameController = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
          left: 16, right: 16, top: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Manage Subreddits', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      hintText: 'Add subreddit...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (v) {
                      if (v.trim().isNotEmpty) {
                        ref.read(settingsProvider.notifier).addSubreddit(v.trim());
                        nameController.clear();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    if (nameController.text.trim().isNotEmpty) {
                      ref.read(settingsProvider.notifier).addSubreddit(nameController.text.trim());
                      nameController.clear();
                    }
                  },
                  child: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (settings.subreddits.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('No subreddits configured', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: settings.subreddits.length,
                  itemBuilder: (_, i) {
                    final sub = settings.subreddits[i];
                    return ListTile(
                      title: Text('r/$sub'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Remove',
                        onPressed: () => ref.read(settingsProvider.notifier).removeSubreddit(sub),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
