import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'platform/web_env.dart'
    if (dart.library.js_interop) 'platform/web_env_web.dart';

/// Whether a newer build has been deployed since this session started.
class AppUpdate {
  const AppUpdate({required this.updateAvailable, this.latestBuildId});

  final bool updateAvailable;
  final String? latestBuildId;

  static const none = AppUpdate(updateAvailable: false);
}

/// Pure decision: is [latest] a different, real build from what we booted with?
/// A missing boot or latest id (dev, offline, 404) never signals an update, so
/// the banner can't false-fire locally.
bool isNewerBuild(String? boot, String? latest) =>
    boot != null && latest != null && boot != latest && latest != 'dev';

/// The build id this session booted with — captured once, then compared against
/// what the server currently serves.
String? _bootBuildId;

Future<String?> _fetchBuildId() async {
  if (!kIsWeb) return null;
  try {
    final uri = Uri.parse(appBaseUrl()).resolve('build-info.json').replace(
      queryParameters: {'t': '${DateTime.now().millisecondsSinceEpoch}'},
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return json['buildId'] as String?;
  } catch (_) {
    return null; // Offline / missing file: treat as "no update", never crash.
  }
}

/// Polls the deployed `build-info.json` and flips to `updateAvailable` once a
/// different build is published — so a tab left open for days can offer a
/// refresh instead of silently running stale code. No-op off the web build.
final appUpdateProvider = StreamProvider<AppUpdate>((ref) async* {
  if (!kIsWeb) {
    yield AppUpdate.none;
    return;
  }
  _bootBuildId ??= await _fetchBuildId();
  yield AppUpdate(updateAvailable: false, latestBuildId: _bootBuildId);

  await for (final _ in Stream<void>.periodic(const Duration(minutes: 3))) {
    final latest = await _fetchBuildId();
    if (isNewerBuild(_bootBuildId, latest)) {
      yield AppUpdate(updateAvailable: true, latestBuildId: latest);
      return; // Once we know an update is out, stop polling; the banner is up.
    }
  }
});

/// Reload the page to load the newest deploy.
void applyUpdate() => reloadApp();
