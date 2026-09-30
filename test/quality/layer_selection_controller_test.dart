import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/quality/layer_selection.dart';
import 'package:cloudflare_realtime/src/quality/layer_selection_controller.dart';
import 'package:cloudflare_realtime/src/quality/simulcast_ladder.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _stage = TileDemand(width: 1280, height: 720); // a
const _gallery = TileDemand(width: 640, height: 360); // b
const _thumb = TileDemand(width: 160, height: 90); // c
const _ms = Duration(milliseconds: 1);

const _a = LayerPreference.rid('a');
const _b = LayerPreference.rid('b');
const _c = LayerPreference.rid('c');
const _paused = LayerPreference.paused();

void main() {
  late List<(String, LayerPreference)> changes;
  late LayerSelectionController controller;

  setUp(() {
    changes = [];
    controller = LayerSelectionController(
      onChange: (id, preference) => changes.add((id, preference)),
    );
  });

  test('the first report is emitted at once', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      expect(changes, [('sub', _b)]);
      expect(controller.preferenceFor('sub'), _b);
      expect(controller.subscriptionIds, ['sub']);
    });
  });

  test('later changes wait for the debounce', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.reportDemand('sub', 'view', _stage);
      async.elapse(_ms * 299);
      expect(changes, [('sub', _b)]);
      async.elapse(_ms);
      expect(changes, [('sub', _b), ('sub', _a)]);
      expect(controller.preferenceFor('sub'), _a);
    });
  });

  test('a change that reverts within the debounce emits nothing', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.reportDemand('sub', 'view', _stage);
      async.elapse(_ms * 200);
      controller.reportDemand('sub', 'view', _gallery);
      async.elapse(_ms * 1000);
      expect(changes, [('sub', _b)]);
    });
  });

  test('a new target restarts the debounce; the same target does not', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.reportDemand('sub', 'view', _stage);
      async.elapse(_ms * 200);
      // Same choice (a), different size: the timer keeps running.
      controller.reportDemand(
        'sub',
        'view',
        const TileDemand(width: 1920, height: 1080),
      );
      async.elapse(_ms * 100);
      expect(changes.last, ('sub', _a));

      controller.reportDemand('sub', 'view', _gallery);
      async.elapse(_ms * 200);
      controller.reportDemand('sub', 'view', _thumb); // New target: restart.
      async.elapse(_ms * 200);
      expect(changes.last, ('sub', _a));
      async.elapse(_ms * 100);
      expect(changes.last, ('sub', _c));
      expect(changes, hasLength(3));
    });
  });

  test('several views: the biggest visible one wins', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'tile', _thumb);
      controller.reportDemand('sub', 'stage', _stage);
      async.elapse(_ms * 300);
      expect(controller.preferenceFor('sub'), _a);

      // The stage view is hidden: back to the thumbnail's layer.
      controller.reportDemand('sub', 'stage', TileDemand.hidden);
      async.elapse(_ms * 300);
      expect(controller.preferenceFor('sub'), _c);

      // The stage view is removed entirely; nothing changes.
      controller.removeView('sub', 'stage');
      async.elapse(_ms * 300);
      expect(changes, [('sub', _c), ('sub', _a), ('sub', _c)]);
    });
  });

  test('removing the last view pauses after the debounce', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.removeView('sub', 'view');
      async.elapse(_ms * 299);
      expect(changes, [('sub', _b)]);
      async.elapse(_ms);
      expect(changes.last, ('sub', _paused));
      // Removing an unknown view is a no-op.
      controller.removeView('sub', 'view');
      controller.removeView('other', 'view');
      async.elapse(_ms * 1000);
      expect(changes, hasLength(2));
    });
  });

  test('hidden, then visible again quickly: no change at all', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.reportDemand('sub', 'view', TileDemand.hidden);
      async.elapse(_ms * 100);
      controller.reportDemand('sub', 'view', _gallery);
      async.elapse(_ms * 1000);
      expect(changes, [('sub', _b)]);
    });
  });

  test('paused to visible is emitted at once', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', TileDemand.hidden);
      expect(changes, [('sub', _paused)]);
      controller.reportDemand('sub', 'view', _stage);
      expect(changes, [('sub', _paused), ('sub', _a)]);
    });
  });

  test('paused to visible cancels a pending change', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.reportDemand('sub', 'view', TileDemand.hidden);
      async.elapse(_ms * 300);
      expect(changes.last, ('sub', _paused));
      controller.reportDemand('sub', 'view', _stage);
      expect(changes.last, ('sub', _a));
      async.elapse(_ms * 1000);
      expect(changes, hasLength(3));
    });
  });

  test('hysteresis uses the emitted layer', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _stage);
      // 500 lines is inside a's downgrade band: stays a.
      controller.reportDemand(
        'sub',
        'view',
        const TileDemand(width: 889, height: 500),
      );
      async.elapse(_ms * 1000);
      expect(changes, [('sub', _a)]);
    });
  });

  test('subscriptions are independent', () {
    fakeAsync((async) {
      controller.reportDemand('one', 'v', _stage);
      controller.reportDemand('two', 'v', _thumb);
      controller.reportDemand('one', 'v', _gallery);
      async.elapse(_ms * 300);
      expect(changes, [('one', _a), ('two', _c), ('one', _b)]);
    });
  });

  test('a repeated identical report does nothing', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.reportDemand('sub', 'view', _gallery);
      async.elapse(_ms * 1000);
      expect(changes, hasLength(1));
    });
  });

  group('ladders', () {
    test('setLadder before any view emits nothing', () {
      fakeAsync((async) {
        controller.setLadder('sub', SimulcastLadder.h720);
        async.elapse(_ms * 1000);
        expect(changes, isEmpty);
        expect(controller.preferenceFor('sub'), isNull);
      });
    });

    test('a smaller publisher ladder limits the layers', () {
      fakeAsync((async) {
        controller.setLadder(
          'sub',
          SimulcastLadder.fromPreset(VideoPreset.h360),
        );
        controller.reportDemand('sub', 'view', _thumb);
        expect(changes, [('sub', _b)]); // No c at 360p.
      });
    });

    test('changing the ladder re-evaluates', () {
      fakeAsync((async) {
        controller.reportDemand('sub', 'view', _thumb);
        controller.setLadder(
          'sub',
          SimulcastLadder.fromPreset(VideoPreset.h360),
        );
        async.elapse(_ms * 300);
        expect(changes, [('sub', _c), ('sub', _b)]);
        // The same ladder again is a no-op.
        controller.setLadder(
          'sub',
          SimulcastLadder.fromPreset(VideoPreset.h360),
        );
        async.elapse(_ms * 300);
        expect(changes, hasLength(2));
      });
    });

    test('the default ladder is configurable', () {
      fakeAsync((async) {
        final custom = LayerSelectionController(
          onChange: (id, p) => changes.add((id, p)),
          defaultLadder: SimulcastLadder.fromPreset(VideoPreset.h180),
        );
        custom.reportDemand('sub', 'view', _stage);
        expect(changes, [('sub', _a)]);
        expect(custom.defaultLadder.layers, hasLength(1));
      });
    });
  });

  test('flush emits pending changes now', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.reportDemand('sub', 'view', _stage);
      controller.flush();
      expect(changes.last, ('sub', _a));
      async.elapse(_ms * 1000);
      expect(changes, hasLength(2));
    });
  });

  test('removeSubscription cancels its pending change', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.reportDemand('sub', 'view', _stage);
      controller.removeSubscription('sub');
      async.elapse(_ms * 1000);
      expect(changes, hasLength(1));
      expect(controller.preferenceFor('sub'), isNull);
      // A fresh report starts over, emitted at once.
      controller.reportDemand('sub', 'view', _thumb);
      expect(changes.last, ('sub', _c));
    });
  });

  test('dispose cancels everything and ignores later reports', () {
    fakeAsync((async) {
      controller.reportDemand('sub', 'view', _gallery);
      controller.reportDemand('sub', 'view', _stage);
      controller.dispose();
      async.elapse(_ms * 1000);
      controller.reportDemand('other', 'view', _stage);
      controller.setLadder('other', SimulcastLadder.h720);
      controller.removeView('sub', 'view');
      expect(changes, hasLength(1));
    });
  });

  test('the policy builds request objects with the fallback set', () {
    expect(controller.policy.simulcastConfig('c').toJson(), {
      'preferredRid': 'c',
      'ridNotAvailable': 'asciibetical',
    });
  });
}
