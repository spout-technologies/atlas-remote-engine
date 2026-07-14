import 'package:flutter_hbb/common.dart';
import 'package:flutter_test/flutter_test.dart';

/// The hub emits deep links of the form
///
///   atlasremote://connect/<peerId>@<host:port>?key=<PERCENT-ENCODED pubkey>
///                                             &password=<otp>
///                                             &relay=<relayHost>
///                                             &alt=<PERCENT-ENCODED "h1;k1,h2;k2">
///
/// `Uri.queryParameters` uses x-www-form-urlencoded semantics, so it decodes `+`
/// as a SPACE. A base64 pubkey routinely contains `+`, `/` and `=`, which is why
/// the hub percent-encodes the key. These tests pin that round-trip: what comes
/// out of `urlLinkToCmdArgs` must be the ORIGINAL base64, byte for byte, folded
/// into the `<id>?key=<K>` form that Rust's `parse_peer_decoration` parses.
void main() {
  group('urlLinkToCmdArgs — key encoding round-trip', () {
    test('connect authority with @host:port and a percent-encoded key', () {
      const key = 'XU1zOo6SpZYfNGlsb3iMNRaEHEDYLsgEirPgI6VNt8c=';
      final encoded = Uri.encodeQueryComponent(key);
      final args = urlLinkToCmdArgs(Uri.parse(
          'atlasremote://connect/123456789@jhb.atlasos.work:21116?key=$encoded'));

      expect(args, isNotNull);
      expect(args![0], '--connect');
      expect(args[1], '123456789@jhb.atlasos.work:21116?key=$key');
    });

    test('a key containing +, / and trailing = survives verbatim', () {
      // The exact hazard: `+` would come back as a SPACE if the hub had not
      // percent-encoded it, and the resulting key would be silently wrong.
      const key = 'a+b/c+d/e==';
      final encoded = Uri.encodeQueryComponent(key);
      expect(encoded, contains('%2B'), reason: '+ must be percent-encoded');

      final args = urlLinkToCmdArgs(Uri.parse(
          'atlasremote://connect/123456789@jhb.atlasos.work:21116?key=$encoded'));

      expect(args![1], '123456789@jhb.atlasos.work:21116?key=$key');
      expect(args[1], contains('+'));
      expect(args[1], isNot(contains(' ')));
    });

    test('a raw + in the query would decode to a space (regression guard)', () {
      // Documents WHY the hub must percent-encode: this is the broken form.
      final args = urlLinkToCmdArgs(Uri.parse(
          'atlasremote://connect/123456789@jhb.atlasos.work:21116?key=a+b'));
      expect(args![1], '123456789@jhb.atlasos.work:21116?key=a b');
    });

    test('password rides alongside the key', () {
      const key = 'KEY+123/abc=';
      final args = urlLinkToCmdArgs(Uri.parse(
          'atlasremote://connect/123456789@jhb.atlasos.work:21116'
          '?key=${Uri.encodeQueryComponent(key)}&password=hunter2'));

      expect(args![0], '--connect');
      expect(args[1], '123456789@jhb.atlasos.work:21116?key=$key');
      expect(args, containsAllInOrder(['--password', 'hunter2']));
    });

    test('the bare <id>/r@<server> form still parses and forces relay', () {
      const key = 'KEY123';
      final args = urlLinkToCmdArgs(
          Uri.parse('atlasremote://123456789/r@jhb.atlasos.work?key=$key'));

      expect(args![0], '--connect');
      expect(args[1], '123456789/r@jhb.atlasos.work?key=$key');
    });

    test('a plain id with no decoration is unchanged', () {
      final args = urlLinkToCmdArgs(Uri.parse('atlasremote://connect/123456789'));
      expect(args, ['--connect', '123456789']);
    });
  });

  group('urlLinkToCmdArgs — alt fallback chain', () {
    test('alt is carried through as --alt-servers, percent-decoded', () {
      const alt = 'eu.atlasos.work:21116;KEY+EU/1=,public;';
      final args = urlLinkToCmdArgs(Uri.parse(
          'atlasremote://connect/123456789@jhb.atlasos.work:21116'
          '?key=KEY123&alt=${Uri.encodeQueryComponent(alt)}'));

      expect(args![1], '123456789@jhb.atlasos.work:21116?key=KEY123');
      final i = args.indexOf('--alt-servers');
      expect(i, greaterThan(0));
      expect(args[i + 1], alt);
    });

    test('alt does not disturb the id, and is simply absent when unset', () {
      final args = urlLinkToCmdArgs(Uri.parse(
          'atlasremote://connect/123456789@jhb.atlasos.work:21116?key=KEY123'));
      expect(args![1], '123456789@jhb.atlasos.work:21116?key=KEY123');
      expect(args, isNot(contains('--alt-servers')));
    });

    test('an empty alt is ignored rather than emitted', () {
      final args = urlLinkToCmdArgs(Uri.parse(
          'atlasremote://connect/123456789@jhb.atlasos.work?key=K&alt='));
      expect(args, isNot(contains('--alt-servers')));
    });

    test('unknown query params are ignored gracefully (old-engine contract)', () {
      final args = urlLinkToCmdArgs(Uri.parse(
          'atlasremote://connect/123456789@jhb.atlasos.work:21116'
          '?key=KEY123&relay=jhb-relay.atlasos.work&region=za&whatever=1'));

      expect(args![0], '--connect');
      expect(args[1], '123456789@jhb.atlasos.work:21116?key=KEY123');
      // `relay` (any value) means force-relay; the rest are simply dropped.
      expect(args, contains('--relay'));
      expect(args, isNot(contains('--region')));
      expect(args, isNot(contains('--whatever')));
    });
  });

  group('parseAltServers', () {
    test('parses an ordered host;key chain', () {
      final c = parseAltServers('eu.atlasos.work:21116;KEYEU,za.atlasos.work;KEYZA');
      expect(c, hasLength(2));
      expect(c[0].server, 'eu.atlasos.work:21116');
      expect(c[0].key, 'KEYEU');
      expect(c[1].server, 'za.atlasos.work');
      expect(c[1].key, 'KEYZA');
    });

    test('a key may itself contain +, / and = (only , and ; are structural)', () {
      final c = parseAltServers('eu.atlasos.work;a+b/c==,fr.atlasos.work;d/e+f=');
      expect(c[0].key, 'a+b/c==');
      expect(c[1].key, 'd/e+f=');
    });

    test('a missing or empty key is allowed', () {
      final c = parseAltServers('eu.atlasos.work,fr.atlasos.work;');
      expect(c, hasLength(2));
      expect(c[0].key, '');
      expect(c[1].key, '');
    });

    test('empty, null and host-less entries yield nothing', () {
      expect(parseAltServers(null), isEmpty);
      expect(parseAltServers(''), isEmpty);
      expect(parseAltServers('   '), isEmpty);
      expect(parseAltServers(',,'), isEmpty);
      expect(parseAltServers(';KEYONLY'), isEmpty);
    });

    test('surrounding whitespace is tolerated, order is preserved', () {
      final c = parseAltServers(' eu.atlasos.work ; KEYEU , za.atlasos.work ; KEYZA ');
      expect(c.map((e) => e.server).toList(),
          ['eu.atlasos.work', 'za.atlasos.work']);
      expect(c.map((e) => e.key).toList(), ['KEYEU', 'KEYZA']);
    });
  });

  group('stripPeerQuery', () {
    test('strips the ?key= decoration for display', () {
      expect(stripPeerQuery('123456789@jhb.atlasos.work:21116?key=abc/d+e='),
          '123456789@jhb.atlasos.work:21116');
    });

    test('leaves an undecorated id alone', () {
      expect(stripPeerQuery('123456789'), '123456789');
      expect(stripPeerQuery('123456789@jhb.atlasos.work'),
          '123456789@jhb.atlasos.work');
    });
  });
}
