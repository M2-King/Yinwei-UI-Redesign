# Native gesture regression

`export_fixtures.mjs` observes the actual calls to `run` and `outs` in the existing
JavaScript oracle; it does not recreate or shorten their frame sequences. The 65
sequences include all 36 attempts in both owner summary replays. Those replays are
reconstructed synthetic motions from measurements, not recorded camera frames.

Only the two owner-approved pose shows changed: a palm flash and each Victory
show around a disappearance now last at most 120 ms. Motion/noise/return cases
and their assertions remain unchanged. The shipped legacy JS core and the design
prototype remain unchanged; the iPad page never invokes that recognition core.

Regenerate, then verify reproducibility:

```sh
node test/native_gestures/export_fixtures.mjs
node test/native_gestures/export_fixtures.mjs --check
```

The macOS entry point is `yinwei/tools/test_ios_capture.sh`. It checks fixture
freshness and compiles the classifier, pure Foundation engine and `main.swift`.
To retain the full timing/results JSON separately:

```sh
swiftc ios/Runner/YinweiHandPose.swift ios/Runner/YinweiGestureEngine.swift \
  test/native_gestures/main.swift -o /tmp/yinwei-gesture-tests
/tmp/yinwei-gesture-tests test/native_gestures/fixtures/oracle.json /tmp/gesture-results.json
```

Each fixture compares the exact ordered event names and each event's camera-frame
time against the old core, with zero misses/extras and no later decisions. The
printed improvement is `old time - new time`, aggregated over matching events.
Native tests also exercise smaller swipes, same-direction repetition, recoil,
dropouts, one-shot holds, flashes, doubtful geometry, moving hands, long gaps,
30/60 fps poses, and a 60 fps swipe. Classifier tests use actual joint geometry;
legacy named-pose fixtures explicitly use margin 1 because they have no joints.

The timer around each engine call uses `DispatchTime.uptimeNanoseconds`. It excludes
classifier construction and Vision. These are host algorithm measurements, not
camera, Vision, bridge, page, audio, thermal or physical-iPad acceptance tests.
