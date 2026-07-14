import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_test/flutter_test.dart';

Peer _peer({
  String id = '123456789',
  String rendezvousServer = '',
  String rendezvousKey = '',
}) =>
    Peer(
      id: id,
      hash: '',
      password: '',
      username: '',
      hostname: '',
      platform: '',
      alias: '',
      tags: [],
      forceAlwaysRelay: false,
      rdpPort: '',
      rdpUsername: '',
      loginName: '',
      device_group_name: '',
      note: '',
      rendezvousServer: rendezvousServer,
      rendezvousKey: rendezvousKey,
    );

void main() {
  group('Peer — per-peer home rendezvous node', () {
    test('fromJson reads the snake_case hub fields', () {
      final peer = Peer.fromJson({
        'id': '123456789',
        'rendezvous_server': 'jhb.atlasos.work:21116',
        'rendezvous_key': 'KEY+abc/123=',
      });

      expect(peer.rendezvousServer, 'jhb.atlasos.work:21116');
      // The AB payload is already-decoded JSON: the key is raw base64 and must
      // NOT be percent-decoded again.
      expect(peer.rendezvousKey, 'KEY+abc/123=');
    });

    test('fromJson defaults to empty when the hub omits the fields', () {
      final peer = Peer.fromJson({'id': '123456789'});
      expect(peer.rendezvousServer, '');
      expect(peer.rendezvousKey, '');
    });

    test('toJson round-trips through fromJson', () {
      final peer = _peer(
          rendezvousServer: 'jhb.atlasos.work:21116', rendezvousKey: 'KEYZA');
      final back = Peer.fromJson(peer.toJson());

      expect(back.rendezvousServer, 'jhb.atlasos.work:21116');
      expect(back.rendezvousKey, 'KEYZA');
    });

    test('toCustomJson carries the home node — the offline-cache trap', () {
      // The offline address-book cache serialises through toCustomJson. If the
      // fields are missing here they vanish on restart and every peer silently
      // falls back to the client's configured rendezvous node.
      final peer = _peer(
          rendezvousServer: 'jhb.atlasos.work:21116', rendezvousKey: 'KEYZA');

      final cached = peer.toCustomJson(includingHash: false);
      expect(cached['rendezvous_server'], 'jhb.atlasos.work:21116');
      expect(cached['rendezvous_key'], 'KEYZA');

      final rehydrated = Peer.fromJson(cached);
      expect(rehydrated.rendezvousServer, 'jhb.atlasos.work:21116');
      expect(rehydrated.rendezvousKey, 'KEYZA');
    });

    test('equal() treats a re-homed peer as changed (so the UI re-syncs)', () {
      final a = _peer(rendezvousServer: 'jhb.atlasos.work', rendezvousKey: 'K1');

      expect(a.equal(_peer(rendezvousServer: 'jhb.atlasos.work', rendezvousKey: 'K1')),
          isTrue);
      // Moved to another region.
      expect(a.equal(_peer(rendezvousServer: 'eu.atlasos.work', rendezvousKey: 'K1')),
          isFalse);
      // Key rotated on the same node.
      expect(a.equal(_peer(rendezvousServer: 'jhb.atlasos.work', rendezvousKey: 'K2')),
          isFalse);
      // Moved back to the default node (cleared).
      expect(a.equal(_peer()), isFalse);
    });

    test('Peer.copy preserves the home node', () {
      final copy = Peer.copy(
          _peer(rendezvousServer: 'eu.atlasos.work:21116', rendezvousKey: 'KEYEU'));

      expect(copy.rendezvousServer, 'eu.atlasos.work:21116');
      expect(copy.rendezvousKey, 'KEYEU');
    });

    test('Peer.loading() still constructs (no required-param break)', () {
      final loading = Peer.loading();
      expect(loading.rendezvousServer, '');
      expect(loading.rendezvousKey, '');
    });
  });

  group('FfiModel.isEstablishmentFailure', () {
    // Establishment-class: the connection never came up. Safe to try another node.
    test('fires on the connection-setup failures raised by client.rs', () {
      for (final text in [
        // client.rs appends ": Please try later" to anything starting "Failed".
        'Failed to connect via rendezvous server: Please try later',
        'Failed to connect via relay server: connection refused: Please try later',
        'Failed to make direct connection to remote desktop: Please try later',
        'Failed to secure tcp: deadline has elapsed: Please try later',
        'Remote desktop is offline',
        'ID does not exist',
      ]) {
        expect(
          FfiModel.isEstablishmentFailure('error', 'Connection Error', text),
          isTrue,
          reason: 'should be establishment-class: $text',
        );
      }
    });

    // The load-bearing negative cases: a technician who mistypes a password must
    // NEVER be silently bounced to another continent.
    test('never fires on auth, key, or non-establishment failures', () {
      const notEstablishment = [
        ['re-input-password', 'Connection Error', 'Wrong Password'],
        ['input-password', 'Password Required', 'Please enter your password'],
        ['input-2fa', '2FA Required', 'Please enter the 2FA code'],
        ['session-login', 'Login', 'login_linux_tip'],
        ['error', 'Connection Error', 'Key mismatch'],
        ['error', 'Connection Error', 'Key overuse'],
        ['error', 'Connection Error', 'No Password Access'],
        ['success', 'Successful', 'Connected, waiting for image...'],
        ['restarting', 'Restarting remote device', 'Connection in progress.'],
        // Right text, wrong envelope — a toast/other title must not qualify.
        ['info', 'Connection Error', 'Remote desktop is offline'],
        ['error', 'Error', 'Failed to connect via relay server'],
      ];

      for (final c in notEstablishment) {
        expect(
          FfiModel.isEstablishmentFailure(c[0], c[1], c[2]),
          isFalse,
          reason: 'must NOT switch node on: ${c[0]} / ${c[1]} / ${c[2]}',
        );
      }
    });
  });
}
