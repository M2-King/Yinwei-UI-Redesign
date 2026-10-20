import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/listen_room_html.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled Listen Room page inlines into one offline document',
      () async {
    final html = await ListenRoomHtml.load();

    // Nothing left to fetch: no external scripts, stylesheets or file URLs.
    expect(html, isNot(contains('<script src=')));
    expect(html, isNot(contains('<link')));
    expect(RegExp(r'url\("(?!data:)').hasMatch(html), isFalse);

    // Fonts and the still picture are embedded.
    expect('data:font/woff2;base64,'.allMatches(html).length, 2);
    expect(html, contains('data:image/jpeg;base64,'));

    // Every script is there, in the page's order.
    final order = [
      'Copyright 2010-2021 Three.js Authors',
      'THREE.CopyShader =',
      'THREE.UnrealBloomPass =',
      'THREE.BufferGeometryUtils =',
      'const RoomMath =',
      'const ListenBridge =',
      'window.YinweiListen =',
      'const OpeningSound =',
      'function buildScene()',
    ];
    final positions = [for (final marker in order) html.indexOf(marker)];
    expect(positions, everyElement(greaterThanOrEqualTo(0)));
    expect([...positions]..sort(), positions);

    // The review stand-in never ships, and no inline script is cut short.
    // (ui.js names dev/dev-host.js only to load it with ?dev, which the app never adds.)
    expect(html, isNot(contains('Listen Room · P1 review')));
    expect(html, isNot(contains('dev-pill')));
    final body =
        html.split('<script>').skip(1).map((s) => s.split('</script>').first);
    for (final script in body) {
      expect(script, isNot(contains('</')));
    }

    // The only web addresses are reference links in three.js comments and the
    // XHTML namespace name; none is fetched.
    final hosts = RegExp(r'https?://([a-z0-9.-]+)')
        .allMatches(html)
        .map((m) => m[1]!)
        .toSet();
    expect(
        hosts.difference({
          'www.w3.org',
          'www.terathon.com',
          'github.com',
          'docs.unrealengine.com',
          'en.wikipedia.org',
        }),
        isEmpty);
  });
}
