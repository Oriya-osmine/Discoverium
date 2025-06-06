import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:provider/provider.dart';

class DiscoveriumApp {
  final String name;
  final String description;
  final String? author;
  final String? url;
  final String? icon;
  final String? releasesUrl;
  final List<String> categories;

  DiscoveriumApp({
    required this.name,
    required this.description,
    this.author,
    this.url,
    this.icon,
    this.releasesUrl,
    this.categories = const [],
  });

  factory DiscoveriumApp.fromYaml(Map<String, dynamic> yaml) {
    // Extract releases URL from nested structure
    String? releasesUrl;
    if (yaml['releases'] is Map && yaml['releases']['url'] != null) {
      releasesUrl = yaml['releases']['url'].toString();
    }

    // Handle both 'author' and 'authors' fields
    String? author;
    if (yaml['author'] != null) {
      author = yaml['author'].toString();
    } else if (yaml['authors'] != null) {
      author = yaml['authors'].toString();
    }

    // Handle both 'categories' (list) and 'category' (single) fields
    List<String> categories = [];
    if (yaml['categories'] is List) {
      categories = (yaml['categories'] as List).map((e) => e.toString()).toList();
    } else if (yaml['category'] != null) {
      categories = [yaml['category'].toString()];
    }

    return DiscoveriumApp(
      name: yaml['name']?.toString() ?? 'Unknown',
      description: yaml['description']?.toString() ?? 'No description',
      author: author,
      url: yaml['url']?.toString(),
      icon: yaml['icon']?.toString(),
      releasesUrl: releasesUrl,
      categories: categories,
    );
  }

  bool matchesSearch(String query) {
    final lowercaseQuery = query.toLowerCase();
    return name.toLowerCase().contains(lowercaseQuery) ||
          description.toLowerCase().contains(lowercaseQuery) ||
          (author?.toLowerCase().contains(lowercaseQuery) ?? false) ||
          categories.any((category) => category.toLowerCase().contains(lowercaseQuery));
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => SearchPageState();
}

class SearchPageState extends State<SearchPage> {
  final TextEditingController _searchController = TextEditingController();
  List<DiscoveriumApp> _allApps = [];
  List<DiscoveriumApp> _filteredApps = [];
  bool _isLoading = false;
  String? _error;
  final Set<String> _failedImageUrls = <String>{};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterApps);
    // Auto-load apps when the page initializes
    _loadApps();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Fetch apps.yml with the new simplified format
      final appsResponse = await http.get(
        Uri.parse('https://raw.githubusercontent.com/cygnusx-1-org/Discoverium/refs/heads/main/repo/apps.yml'),
      );

      if (appsResponse.statusCode != 200) {
        throw Exception('Failed to load apps.yml: ${appsResponse.statusCode}');
      }

      // Parse apps.yml directly as a list of apps
      final appsYaml = loadYaml(appsResponse.body);

      final List<DiscoveriumApp> apps = [];

      // The YAML is now directly a list of app objects
      if (appsYaml is List) {
        for (final appData in appsYaml) {
          if (appData is Map) {
            try {
              apps.add(DiscoveriumApp.fromYaml(Map<String, dynamic>.from(appData)));
            } catch (e) {
              print('Error parsing app data: $e');
              // Continue with other apps even if one fails
            }
          }
        }
      }

      setState(() {
        _allApps = apps;
        _filteredApps = apps;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _filterApps() {
    final query = _searchController.text;
    setState(() {
      if (query.isEmpty) {
        _filteredApps = _allApps;
      } else {
        _filteredApps = _allApps.where((app) => app.matchesSearch(query)).toList();
      }
    });
  }

  Future<void> _showAddAppDialog(DiscoveriumApp app) async {
    if (app.releasesUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('noReleasesUrl')),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(app.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(app.description),
              const SizedBox(height: 16),
              Text(
                tr('addAppConfirmation'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (app.author != null) ...[
                const SizedBox(height: 8),
                Text(
                  'By ${app.author}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('add')),
            ),
          ],
        );
      },
    );

    if (result == true) {
      await _addAppToMainList(app.releasesUrl!);
    }
  }

  Future<void> _addAppToMainList(String releasesUrl) async {
    try {
      // Get providers
      final appsProvider = context.read<AppsProvider>();
      final settingsProvider = context.read<SettingsProvider>();
      final notificationsProvider = context.read<NotificationsProvider>();
      final sourceProvider = SourceProvider();

      // Show loading state
      setState(() {
        _isLoading = true;
      });

      // Get app info from the releases URL
      final app = await sourceProvider.getApp(
        sourceProvider.getSource(releasesUrl),
        releasesUrl.trim(),
        {},
        trackOnlyOverride: false,
        sourceIsOverriden: false,
        inferAppIdIfOptional: true,
      );

      // Check if app already exists
      if (appsProvider.apps.containsKey(app.id)) {
        throw ObtainiumError(tr('appAlreadyAdded'));
      }

      // Download APK if needed for package ID (only if not track-only)
      if (isTempId(app) && app.additionalSettings['trackOnly'] != true) {
        final apkUrl = await appsProvider.confirmAppFileUrl(app, context, false);
        if (apkUrl == null) {
          throw ObtainiumError(tr('cancelled'));
        }
        app.preferredApkIndex = app.apkUrls.map((e) => e.value).toList().indexOf(apkUrl.value);

        final downloadedArtifact = await appsProvider.downloadApp(
          app,
          globalNavigatorKey.currentContext,
          notificationsProvider: notificationsProvider,
        );

        DownloadedApk? downloadedFile;
        DownloadedXApkDir? downloadedDir;
        if (downloadedArtifact is DownloadedApk) {
          downloadedFile = downloadedArtifact;
        } else {
          downloadedDir = downloadedArtifact as DownloadedXApkDir;
        }
        app.id = downloadedFile?.appId ?? downloadedDir!.appId;
      }

      // Set installed version for track-only or non-version-detection apps
      if (app.additionalSettings['trackOnly'] == true ||
          app.additionalSettings['versionDetection'] != true) {
        app.installedVersion = app.latestVersion;
      }

      // Save the app
      await appsProvider.saveApps([app], onlyIfExists: false);

      // Show success message and navigate to app page
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('appAdded')),
          action: SnackBarAction(
            label: tr('view'),
            onPressed: () {
              Navigator.push(
                globalNavigatorKey.currentContext ?? context,
                MaterialPageRoute(builder: (context) => AppPage(appId: app.id)),
              );
            },
          ),
        ),
      );
    } catch (e) {
      showError(e, context);
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('searchApps')),
        elevation: 0,
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: tr('searchHint'),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_allApps.isEmpty && !_isLoading && _error != null)
                  ElevatedButton.icon(
                    onPressed: _loadApps,
                    icon: const Icon(Icons.refresh),
                    label: Text(tr('retry')),
                  ),
              ],
            ),
          ),

          // Content area
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 64,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              tr('errorOccurred'),
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadApps,
                              child: Text(tr('retry')),
                            ),
                          ],
                        ),
                      )
                    : _filteredApps.isEmpty && _allApps.isNotEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.search_off,
                                  size: 64,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  tr('noResultsFound'),
                                  style: Theme.of(context).textTheme.headlineSmall,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  tr('tryDifferentSearch'),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          )
                        : _allApps.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.apps,
                                      size: 64,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      tr('noAppsLoaded'),
                                      style: Theme.of(context).textTheme.headlineSmall,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      tr('loadAppsToSearch'),
                                      style: Theme.of(context).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                itemCount: _filteredApps.length,
                                itemBuilder: (context, index) {
                                  final app = _filteredApps[index];
                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 4,
                                    ),
                                    child: ListTile(
                                      leading: app.icon != null && !_failedImageUrls.contains(app.icon!)
                                          ? CircleAvatar(
                                              backgroundColor: Colors.white,
                                              backgroundImage: NetworkImage(app.icon!),
                                              onBackgroundImageError: (_, __) {
                                                setState(() {
                                                  _failedImageUrls.add(app.icon!);
                                                });
                                              },
                                            )
                                          : const CircleAvatar(
                                              child: Icon(Icons.apps),
                                            ),
                                      title: Text(
                                        app.name,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(app.description),
                                          if (app.author != null) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              'By ${app.author}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                          if (app.categories.isNotEmpty) ...[
                                            const SizedBox(height: 4),
                                            Wrap(
                                              spacing: 4,
                                              children: app.categories.map((category) =>
                                                Chip(
                                                  label: Text(
                                                    category,
                                                    style: const TextStyle(fontSize: 10),
                                                  ),
                                                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                  visualDensity: VisualDensity.compact,
                                                ),
                                              ).toList(),
                                            ),
                                          ],
                                        ],
                                      ),
                                      isThreeLine: true,
                                      onTap: app.releasesUrl != null
                                          ? () {
                                              _showAddAppDialog(app);
                                            }
                                          : null,
                                    ),
                                  );
                                },
                              ),
          ),
        ],
      ),
    );
  }
}