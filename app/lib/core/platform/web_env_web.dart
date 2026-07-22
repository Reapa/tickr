import 'package:web/web.dart' as web;

/// The document's resolved base URL (honours the `<base href>` Flutter sets to
/// the Pages sub-path), so `build-info.json` resolves next to `index.html`.
String appBaseUrl() => web.document.baseURI;

/// Hard-reload the page to pick up a freshly deployed build.
void reloadApp() => web.window.location.reload();
