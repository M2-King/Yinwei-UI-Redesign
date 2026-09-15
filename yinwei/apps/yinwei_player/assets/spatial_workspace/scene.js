/* Yinwei spatial workspace — Three.js r160, Apple-dark, no neon HUD.
   Flutter SpatialSceneStore is authoritative. JS proposes world-XYZ intents.
   Visual emitters are layout-only — not discrete 7.1 / Array channels.
   Speaker drag is visual-only and does not commit acoustic scene state. */
(function () {
  'use strict';

  window.addEventListener('error', function (e) {
    var hint = document.getElementById('hint');
    if (hint) hint.textContent = e.message || String(e.error || e);
  });

  var DEG = Math.PI / 180;
  var ROOM = 6.4;
  var WALL_H = 3.2;
  var MAX_DPR = 1.5;
  var POSE_MS = 32;

  var state = {
    envelopment: 0.6,
    playhead: 0,
    playing: false,
    active: true,
    orbiting: false,
  };

  var viewMode = 'free';
  var dragging = null;
  var lastPosePost = 0;
  var needsRender = true;
  var waveAcc = 0;
  var trail = [];
  var viewTween = null;
  var objectsById = {};
  var authoritativeRevision = 0;
  var selectedObjectId = null;
  var source = null;
  var listener = null;

  function xyzToPose(v) {
    var dist = v.length();
    if (dist < 1e-6) {
      return { azimuth: 0, elevation: 0, distance: 0 };
    }
    var el = Math.asin(THREE.MathUtils.clamp(v.y / dist, -1, 1)) / DEG;
    var az = Math.atan2(v.x, -v.z) / DEG;
    if (az > 180) az -= 360;
    if (az <= -180) az += 360;
    return { azimuth: az, elevation: THREE.MathUtils.clamp(el, -90, 90), distance: dist };
  }

  function quatDomainToThree(q) {
    return { x: q.x, y: q.y, z: q.z, w: q.w };
  }

  var scene = new THREE.Scene();
  scene.background = new THREE.Color(0x0b0b0d);
  scene.fog = new THREE.Fog(0x0b0b0d, 9, 18);

  var camera = new THREE.PerspectiveCamera(42, 1, 0.08, 40);
  var camSph = new THREE.Spherical(5.4, 1.12, -0.55);
  var camTarget = new THREE.Vector3(0, 0.55, 0);
  function placeCamera() {
    camera.position.setFromSpherical(camSph).add(camTarget);
    camera.lookAt(camTarget);
  }
  placeCamera();

  var renderer;
  try {
    renderer = new THREE.WebGLRenderer({
      antialias: true,
      alpha: false,
      powerPreference: 'default',
      failIfMajorPerformanceCaveat: false,
      preserveDrawingBuffer: true,
    });
  } catch (err) {
    document.getElementById('hint').textContent = 'WebGL unavailable: ' + err;
    throw err;
  }
  renderer.setClearColor(0x0b0b0d, 1);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.shadowMap.enabled = false;
  document.body.appendChild(renderer.domElement);
  if (!renderer.getContext()) {
    document.getElementById('hint').textContent = 'WebGL context missing';
  }

  function capDpr() {
    var dpr = Math.min(window.devicePixelRatio || 1, MAX_DPR);
    renderer.setPixelRatio(dpr);
  }

  function onResize() {
    var w = Math.max(1, window.innerWidth);
    var h = Math.max(1, window.innerHeight);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    capDpr();
    renderer.setSize(w, h, false);
    needsRender = true;
  }
  window.addEventListener('resize', onResize);
  if (window.ResizeObserver) {
    new ResizeObserver(onResize).observe(document.documentElement);
  }
  onResize();

  scene.add(new THREE.HemisphereLight(0xc5ccd6, 0x2a2a2e, 0.95));
  var key = new THREE.DirectionalLight(0xf7f7fa, 0.85);
  key.position.set(2.2, 5.4, 3.1);
  scene.add(key);
  var fill = new THREE.DirectionalLight(0xb0b0b8, 0.28);
  fill.position.set(-3, 1.4, -2);
  scene.add(fill);

  var matWall = new THREE.MeshPhongMaterial({
    color: 0x2a2a30,
    shininess: 8,
  });
  var matFloor = new THREE.MeshPhongMaterial({
    color: 0x1c1c20,
    shininess: 6,
  });
  var matAbsorber = new THREE.MeshPhongMaterial({
    color: 0x323238,
    shininess: 4,
  });
  var matListener = new THREE.MeshPhongMaterial({
    color: 0xe8e8ed,
    shininess: 18,
  });
  var matSpeaker = new THREE.MeshPhongMaterial({
    color: 0x4a4a50,
    shininess: 22,
  });
  var matDriver = new THREE.MeshPhongMaterial({
    color: 0x6e6e73,
    shininess: 40,
  });
  var matSource = new THREE.MeshPhongMaterial({
    color: 0x0a84ff,
    emissive: 0x0a84ff,
    emissiveIntensity: 0.28,
    shininess: 50,
  });
  var matDome = new THREE.MeshPhongMaterial({
    color: 0x3a4a5c,
    shininess: 12,
    transparent: true,
    opacity: 0.07,
    side: THREE.DoubleSide,
    depthWrite: false,
  });

  function buildRoom() {
    var g = new THREE.Group();
    var floor = new THREE.Mesh(new THREE.PlaneGeometry(ROOM, ROOM), matFloor);
    floor.rotation.x = -Math.PI / 2;
    g.add(floor);

    var grid = new THREE.GridHelper(ROOM, 16, 0x2a2a30, 0x1c1c20);
    grid.position.y = 0.002;
    var gm = grid.material;
    (Array.isArray(gm) ? gm : [gm]).forEach(function (m) {
      m.transparent = true;
      m.opacity = 0.45;
    });
    g.add(grid);

    function wall(w, h, d, x, y, z) {
      var m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), matWall);
      m.position.set(x, y, z);
      g.add(m);
    }
    var t = 0.08;
    var y = WALL_H / 2;
    wall(ROOM + t, WALL_H, t, 0, y, -ROOM / 2);
    wall(ROOM + t, WALL_H, t, 0, y, ROOM / 2);
    wall(t, WALL_H, ROOM, -ROOM / 2, y, 0);
    wall(t, WALL_H, ROOM, ROOM / 2, y, 0);
    var ceil = new THREE.Mesh(new THREE.BoxGeometry(ROOM, t, ROOM), matWall);
    ceil.position.y = WALL_H;
    g.add(ceil);

    function panel(w, h, x, y0, z, ry) {
      var m = new THREE.Mesh(new THREE.BoxGeometry(w, h, 0.045), matAbsorber);
      m.position.set(x, y0, z);
      m.rotation.y = ry || 0;
      g.add(m);
    }
    panel(1.4, 0.9, -1.6, 1.55, -ROOM / 2 + 0.07);
    panel(1.4, 0.9, 1.6, 1.55, -ROOM / 2 + 0.07);
    panel(1.1, 1.2, -ROOM / 2 + 0.07, 1.4, 0.8, Math.PI / 2);
    panel(1.1, 1.2, ROOM / 2 - 0.07, 1.4, 0.8, Math.PI / 2);

    var dome = new THREE.Mesh(new THREE.SphereGeometry(2.55, 32, 16, 0, Math.PI * 2, 0, Math.PI / 2), matDome);
    dome.position.y = 0.02;
    g.add(dome);
    var domeWire = new THREE.LineSegments(
      new THREE.WireframeGeometry(new THREE.SphereGeometry(2.56, 16, 8, 0, Math.PI * 2, 0, Math.PI / 2)),
      new THREE.LineBasicMaterial({ color: 0x4a6a90, transparent: true, opacity: 0.22 })
    );
    domeWire.position.y = 0.02;
    g.add(domeWire);

    var distMat = new THREE.LineBasicMaterial({ color: 0x3a5a80, transparent: true, opacity: 0.28 });
    [1, 2, 3.2].forEach(function (r) {
      var pts = new THREE.EllipseCurve(0, 0, r, r, 0, Math.PI * 2, false, 0).getPoints(64).map(function (p) {
        return new THREE.Vector3(p.x, 0.015, p.y);
      });
      g.add(new THREE.LineLoop(new THREE.BufferGeometry().setFromPoints(pts), distMat));
    });

    scene.add(g);
  }
  buildRoom();

  function makeListenerMesh() {
    var g = new THREE.Group();
    var head = new THREE.Mesh(new THREE.SphereGeometry(0.11, 20, 16), matListener);
    head.scale.set(0.92, 1.05, 0.96);
    head.position.y = 1.18;
    var earL = new THREE.Mesh(new THREE.SphereGeometry(0.028, 10, 8), matListener);
    earL.position.set(-0.11, 1.17, 0);
    var earR = earL.clone();
    earR.position.x = 0.11;
    var torso = new THREE.Mesh(new THREE.CylinderGeometry(0.13, 0.16, 0.42, 16), matListener);
    torso.position.y = 0.82;
    g.add(head, earL, earR, torso);
    g.userData.kind = 'listener';
    return g;
  }

  function makeEmitterMesh(obj) {
    var g = new THREE.Group();
    var body = new THREE.Mesh(new THREE.BoxGeometry(0.22, 0.38, 0.2), matSpeaker.clone());
    var driver = new THREE.Mesh(new THREE.CylinderGeometry(0.07, 0.07, 0.018, 22), matDriver);
    driver.rotation.x = Math.PI / 2;
    driver.position.z = 0.11;
    var tweeter = new THREE.Mesh(new THREE.CylinderGeometry(0.028, 0.028, 0.016, 16), matDriver);
    tweeter.rotation.x = Math.PI / 2;
    tweeter.position.set(0, 0.1, 0.108);
    g.add(body, driver, tweeter);
    g.userData.kind = 'emitter';
    g.userData.body = body;
    g.userData.visualRole = obj && obj.visualRole;
    return g;
  }

  function makeSourceMesh() {
    var g = new THREE.Group();
    var mesh = new THREE.Mesh(new THREE.IcosahedronGeometry(0.1, 1), matSource);
    var hit = new THREE.Mesh(
      new THREE.SphereGeometry(0.32, 12, 10),
      new THREE.MeshBasicMaterial({ visible: false })
    );
    g.add(mesh, hit);
    g.userData.kind = 'source';
    g.userData.visual = mesh;
    return g;
  }

  var sourceRing = new THREE.Mesh(
    new THREE.RingGeometry(0.16, 0.175, 48),
    new THREE.MeshBasicMaterial({
      color: 0xffffff,
      transparent: true,
      opacity: 0.18,
      side: THREE.DoubleSide,
      depthWrite: false,
    })
  );
  sourceRing.rotation.x = -Math.PI / 2;
  scene.add(sourceRing);

  var waveGroup = new THREE.Group();
  scene.add(waveGroup);
  var waves = [];
  function makeWave() {
    var geo = new THREE.RingGeometry(0.2, 0.22, 48);
    var mat = new THREE.MeshBasicMaterial({
      color: 0x7aa2c8,
      transparent: true,
      opacity: 0,
      side: THREE.DoubleSide,
      depthWrite: false,
    });
    var mesh = new THREE.Mesh(geo, mat);
    mesh.rotation.x = -Math.PI / 2;
    mesh.userData.age = 999;
    waveGroup.add(mesh);
    waves.push(mesh);
  }
  for (var wi = 0; wi < 4; wi++) makeWave();

  var trailLine = new THREE.Line(
    new THREE.BufferGeometry(),
    new THREE.LineBasicMaterial({ color: 0x0a84ff, transparent: true, opacity: 0.35 })
  );
  scene.add(trailLine);

  var selectBox = new THREE.BoxHelper(new THREE.Object3D(), 0x0a84ff);
  selectBox.visible = false;
  scene.add(selectBox);

  function worldOf(obj) {
    var p = obj.worldPosition || {};
    return new THREE.Vector3(p.x || 0, p.y || 0, p.z || 0);
  }

  function applyDomainOrientation(mesh, obj) {
    if (!obj || !obj.orientation) return;
    var q = quatDomainToThree(obj.orientation);
    mesh.quaternion.set(q.x, q.y, q.z, q.w);
  }

  function decorateSourceVisual(mesh) {
    if (!mesh) return;
    sourceRing.position.set(mesh.position.x, 0.03, mesh.position.z);
    var dist = mesh.position.length();
    var s = 0.55 + Math.min(1, dist / 4) * 0.5;
    sourceRing.scale.setScalar(s);
    matSource.emissiveIntensity = state.active ? 0.22 + state.envelopment * 0.12 : 0.08;
  }

  function formatPose() {
    if (!source) {
      document.getElementById('pose').innerHTML =
        '<span>Az</span>—  <span>El</span>—  <span>Dist</span>—';
      return;
    }
    var pose = xyzToPose(source.position);
    document.getElementById('pose').innerHTML =
      '<span>Az</span>' +
      Math.round(pose.azimuth) +
      '°  <span>El</span>' +
      Math.round(pose.elevation) +
      '°  <span>Dist</span>' +
      pose.distance.toFixed(2) +
      ' m';
  }

  function showSelectionHud(mesh) {
    var el = document.getElementById('sel');
    if (!mesh) {
      el.style.display = 'none';
      selectBox.visible = false;
      return;
    }
    var kind = mesh.userData.kind;
    var pose = xyzToPose(mesh.position);
    var xyz = mesh.position;
    var title = mesh.userData.id || kind;
    var note =
      kind === 'emitter'
        ? 'visual layout · not acoustic Array'
        : kind === 'source'
          ? 'Point source · Flutter owns scene'
          : 'listener';
    el.style.display = 'block';
    el.innerHTML =
      '<div class="ch">' +
      title +
      '</div><div class="muted">' +
      note +
      '</div>' +
      '<div>Az ' +
      Math.round(pose.azimuth) +
      '° · El ' +
      Math.round(pose.elevation) +
      '° · ' +
      pose.distance.toFixed(2) +
      ' m</div>' +
      '<div class="muted">XYZ ' +
      xyz.x.toFixed(2) +
      '  ' +
      xyz.y.toFixed(2) +
      '  ' +
      xyz.z.toFixed(2) +
      '</div>';
    selectBox.setFromObject(mesh);
    selectBox.visible = true;
    needsRender = true;
  }

  function createMeshFor(obj) {
    var mesh;
    if (obj.type === 'listener') mesh = makeListenerMesh();
    else if (obj.type === 'source') mesh = makeSourceMesh();
    else mesh = makeEmitterMesh(obj);
    mesh.userData.id = obj.id;
    mesh.userData.kind = obj.type;
    scene.add(mesh);
    objectsById[obj.id] = mesh;
    if (obj.type === 'listener') listener = mesh;
    if (obj.type === 'source') source = mesh;
    return mesh;
  }

  function updateMeshTransform(mesh, obj, skipSource) {
    if (skipSource && mesh.userData.kind === 'source') return;
    mesh.position.copy(worldOf(obj));
    applyDomainOrientation(mesh, obj);
    if (mesh.userData.kind === 'emitter') {
      mesh.lookAt(new THREE.Vector3(0, mesh.position.y, 0));
      mesh.userData.visualRole = obj.visualRole;
    }
    if (mesh.userData.kind === 'source') {
      source = mesh;
      decorateSourceVisual(mesh);
    }
    if (mesh.userData.kind === 'listener') listener = mesh;
  }

  function applySceneSnapshot(msg) {
    if (!msg || !msg.scene) return;
    authoritativeRevision = msg.revision || msg.scene.revision || 0;
    var sceneDoc = msg.scene;
    var incoming = {};
    var skipSource =
      dragging && dragging.kind === 'source' ? dragging.objectId : null;

    function upsert(obj) {
      if (!obj || !obj.id) return;
      incoming[obj.id] = true;
      var mesh = objectsById[obj.id];
      if (!mesh) mesh = createMeshFor(obj);
      updateMeshTransform(mesh, obj, skipSource && obj.id === skipSource);
    }

    upsert(sceneDoc.listener);
    (sceneDoc.sources || []).forEach(upsert);
    (sceneDoc.emitters || []).forEach(upsert);

    Object.keys(objectsById).forEach(function (id) {
      if (incoming[id]) return;
      var mesh = objectsById[id];
      scene.remove(mesh);
      delete objectsById[id];
      if (source === mesh) source = null;
      if (listener === mesh) listener = null;
    });

    formatPose();
    onResize();
    if (selectedObjectId && objectsById[selectedObjectId]) {
      showSelectionHud(objectsById[selectedObjectId]);
    } else if (!selectedObjectId) {
      showSelectionHud(null);
    }
    needsRender = true;
  }

  function applyPlaybackTelemetry(next) {
    if (!next) return;
    if (typeof next.envelopment === 'number') state.envelopment = next.envelopment;
    if (typeof next.playhead === 'number') state.playhead = next.playhead;
    if (typeof next.playing === 'boolean') state.playing = next.playing;
    if (typeof next.active === 'boolean') state.active = next.active;
    if (typeof next.orbiting === 'boolean') state.orbiting = next.orbiting;
    decorateSourceVisual(source);
    needsRender = true;
  }

  function applyUiState(next) {
    if (!next) return;
    selectedObjectId = next.selectedObjectId || null;
    if (selectedObjectId && objectsById[selectedObjectId]) {
      showSelectionHud(objectsById[selectedObjectId]);
    } else {
      showSelectionHud(null);
    }
  }

  function postToHost(payload) {
    if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') {
      window.chrome.webview.postMessage(payload);
      return;
    }
    var msg = JSON.stringify(payload);
    if (window.YinweiPose && typeof window.YinweiPose.postMessage === 'function') {
      window.YinweiPose.postMessage(msg);
    }
  }

  function postSourceIntent(type, force) {
    if (!source) return;
    var now = performance.now();
    if (!force && type === 'sourcePosePreview' && now - lastPosePost < POSE_MS) return;
    lastPosePost = now;
    postToHost({
      type: type,
      objectId: source.userData.id,
      worldPosition: {
        x: source.position.x,
        y: source.position.y,
        z: source.position.z,
      },
      basedOnRevision: authoritativeRevision,
    });
  }

  var raycaster = new THREE.Raycaster();
  var pointer = new THREE.Vector2();
  var dragPlane = new THREE.Plane();
  var dragHit = new THREE.Vector3();
  var orbitingCam = false;
  var panningCam = false;
  var lastPtr = { x: 0, y: 0 };
  var camEnabled = true;

  function ndcFromEvent(ev) {
    var r = renderer.domElement.getBoundingClientRect();
    pointer.x = ((ev.clientX - r.left) / r.width) * 2 - 1;
    pointer.y = -((ev.clientY - r.top) / r.height) * 2 + 1;
  }

  function pickableMeshes() {
    return Object.keys(objectsById).map(function (id) {
      return objectsById[id];
    });
  }

  function pick(ev) {
    ndcFromEvent(ev);
    raycaster.setFromCamera(pointer, camera);
    var hits = raycaster.intersectObjects(pickableMeshes(), true);
    if (!hits.length) return null;
    var first = null;
    for (var i = 0; i < hits.length; i++) {
      var obj = hits[i].object;
      while (obj && !obj.userData.kind) obj = obj.parent;
      if (!obj) continue;
      if (!first) first = obj;
      if (obj.userData.kind === 'source') return obj;
    }
    return first;
  }

  renderer.domElement.addEventListener('contextmenu', function (e) {
    e.preventDefault();
  });

  renderer.domElement.addEventListener('pointerdown', function (e) {
    ndcFromEvent(e);
    lastPtr.x = e.clientX;
    lastPtr.y = e.clientY;
    var obj = pick(e);
    if (e.button === 0 && obj && obj.userData.kind === 'source') {
      dragging = { kind: 'source', objectId: obj.userData.id };
      dragPlane.setFromNormalAndCoplanarPoint(new THREE.Vector3(0, 1, 0), obj.position);
      selectedObjectId = obj.userData.id;
      postToHost({ type: 'selectObject', objectId: obj.userData.id });
      showSelectionHud(obj);
      renderer.domElement.setPointerCapture(e.pointerId);
      return;
    }
    if (e.button === 0 && obj && obj.userData.kind === 'emitter') {
      // Visual-only until Phase 3. Selection is UI state, not SceneContract.
      selectedObjectId = obj.userData.id;
      postToHost({ type: 'selectObject', objectId: obj.userData.id });
      showSelectionHud(obj);
      renderer.domElement.setPointerCapture(e.pointerId);
      return;
    }
    if (e.button === 2 || e.button === 1) {
      panningCam = true;
    } else if (e.button === 0 && viewMode === 'free') {
      orbitingCam = true;
    }
    if (obj && obj.userData.id) {
      selectedObjectId = obj.userData.id;
      postToHost({ type: 'selectObject', objectId: obj.userData.id });
      showSelectionHud(obj);
    } else if (!obj) {
      selectedObjectId = null;
      postToHost({ type: 'selectObject', objectId: null });
      showSelectionHud(null);
    }
    renderer.domElement.setPointerCapture(e.pointerId);
  });

  renderer.domElement.addEventListener('pointermove', function (e) {
    var dx = e.clientX - lastPtr.x;
    var dy = e.clientY - lastPtr.y;
    lastPtr.x = e.clientX;
    lastPtr.y = e.clientY;
    if (dragging && dragging.kind === 'source' && source) {
      ndcFromEvent(e);
      raycaster.setFromCamera(pointer, camera);
      if (e.shiftKey) {
        dragPlane.setFromNormalAndCoplanarPoint(
          camera.getWorldDirection(new THREE.Vector3()).cross(camera.up).normalize().cross(camera.up).normalize(),
          source.position
        );
      }
      if (raycaster.ray.intersectPlane(dragPlane, dragHit)) {
        dragHit.x = THREE.MathUtils.clamp(dragHit.x, -ROOM * 0.42, ROOM * 0.42);
        dragHit.z = THREE.MathUtils.clamp(dragHit.z, -ROOM * 0.42, ROOM * 0.42);
        dragHit.y = THREE.MathUtils.clamp(dragHit.y, 0.12, WALL_H - 0.3);
        source.position.copy(dragHit);
        decorateSourceVisual(source);
        formatPose();
        postSourceIntent('sourcePosePreview', false);
        needsRender = true;
      }
      return;
    }
    if (orbitingCam && camEnabled && viewMode === 'free') {
      camSph.theta -= dx * 0.005;
      camSph.phi = THREE.MathUtils.clamp(camSph.phi + dy * 0.005, 0.12, Math.PI - 0.18);
      placeCamera();
      needsRender = true;
    }
    if (panningCam && camEnabled) {
      var pan = new THREE.Vector3();
      var right = new THREE.Vector3();
      camera.getWorldDirection(pan);
      right.crossVectors(pan, camera.up).normalize();
      var up = camera.up.clone().normalize();
      camTarget.addScaledVector(right, -dx * 0.004 * camSph.radius);
      camTarget.addScaledVector(up, dy * 0.004 * camSph.radius);
      placeCamera();
      needsRender = true;
    }
  });

  renderer.domElement.addEventListener('pointerup', function () {
    if (dragging && dragging.kind === 'source') {
      postSourceIntent('sourcePoseCommit', true);
    }
    dragging = null;
    orbitingCam = false;
    panningCam = false;
  });

  renderer.domElement.addEventListener(
    'wheel',
    function (e) {
      e.preventDefault();
      if (dragging && dragging.kind === 'source' && source) {
        var len = Math.max(1e-6, source.position.length());
        var next = THREE.MathUtils.clamp(len + (e.deltaY > 0 ? 0.12 : -0.12), 0.12, 8);
        source.position.setLength(next);
        decorateSourceVisual(source);
        formatPose();
        postSourceIntent('sourcePosePreview', false);
        needsRender = true;
        return;
      }
      camSph.radius = THREE.MathUtils.clamp(camSph.radius * (e.deltaY > 0 ? 1.07 : 0.93), 1.6, 12);
      placeCamera();
      needsRender = true;
    },
    { passive: false }
  );

  var VIEW = {
    free: { radius: 5.4, phi: 1.12, theta: -0.55, target: new THREE.Vector3(0, 0.55, 0) },
    top: { radius: 6.2, phi: 0.08, theta: 0, target: new THREE.Vector3(0, 0, 0) },
    front: { radius: 5.6, phi: 1.35, theta: 0, target: new THREE.Vector3(0, 0.7, 0) },
    listener: { radius: 1.15, phi: 1.45, theta: Math.PI, target: new THREE.Vector3(0, 1.12, 0) },
  };

  function setView(name) {
    viewMode = name;
    var v = VIEW[name] || VIEW.free;
    viewTween = {
      t0: performance.now(),
      dur: 380,
      fromR: camSph.radius,
      fromP: camSph.phi,
      fromT: camSph.theta,
      fromTarget: camTarget.clone(),
      toR: v.radius,
      toP: v.phi,
      toT: v.theta,
      toTarget: v.target.clone(),
    };
    document.querySelectorAll('#views button').forEach(function (b) {
      b.classList.toggle('on', b.getAttribute('data-view') === name);
    });
    needsRender = true;
  }

  document.getElementById('views').addEventListener('click', function (e) {
    var btn = e.target.closest('button');
    if (!btn) return;
    setView(btn.getAttribute('data-view'));
  });

  function spawnWave() {
    if (!source) return;
    for (var i = 0; i < waves.length; i++) {
      if (waves[i].userData.age > 1.35) {
        waves[i].userData.age = 0;
        waves[i].position.copy(source.position);
        waves[i].position.y = Math.max(0.05, source.position.y);
        return;
      }
    }
  }

  function updateWaves(dt) {
    var live = state.playing && state.active;
    waveGroup.visible = live;
    if (!live) return;
    waveAcc += dt;
    var interval = 0.72 - state.envelopment * 0.18;
    if (waveAcc >= interval) {
      waveAcc = 0;
      spawnWave();
    }
    var spread = 0.9 + state.envelopment * 1.4;
    var dist = source ? source.position.length() : 1;
    waves.forEach(function (w) {
      w.userData.age += dt;
      var t = w.userData.age / 1.4;
      if (t >= 1) {
        w.material.opacity = 0;
        return;
      }
      var sc = 0.25 + t * (1.1 + dist * 0.15) * spread;
      w.scale.set(sc, sc, sc);
      w.material.opacity = (1 - t) * 0.28;
    });
  }

  function updateTrail() {
    if (!source || !state.orbiting || !state.playing) {
      if (trail.length) {
        trail = [];
        trailLine.geometry.dispose();
        trailLine.geometry = new THREE.BufferGeometry();
      }
      return;
    }
    trail.push(source.position.clone());
    if (trail.length > 48) trail.shift();
    trailLine.geometry.dispose();
    trailLine.geometry = new THREE.BufferGeometry().setFromPoints(trail);
  }

  var lastT = performance.now();
  var frame = 0;
  function tick(now) {
    requestAnimationFrame(tick);
    var dt = Math.min(0.05, (now - lastT) / 1000);
    lastT = now;
    frame++;

    if (viewTween) {
      var k = Math.min(1, (now - viewTween.t0) / viewTween.dur);
      var e = 1 - Math.pow(1 - k, 3);
      camSph.radius = viewTween.fromR + (viewTween.toR - viewTween.fromR) * e;
      camSph.phi = viewTween.fromP + (viewTween.toP - viewTween.fromP) * e;
      camSph.theta = viewTween.fromT + (viewTween.toT - viewTween.fromT) * e;
      camTarget.lerpVectors(viewTween.fromTarget, viewTween.toTarget, e);
      placeCamera();
      needsRender = true;
      if (k >= 1) viewTween = null;
    }

    var animate = (state.playing && state.active) || state.orbiting || dragging;
    if (animate) {
      if (frame % 3 === 0) {
        updateWaves(dt * 3);
        updateTrail();
      }
      if (source) source.rotation.y += dt * 0.4;
      needsRender = true;
    } else if (waveGroup.visible) {
      waveGroup.visible = false;
      needsRender = true;
    }

    if (needsRender) {
      renderer.render(scene, camera);
      needsRender = false;
    }
  }
  requestAnimationFrame(tick);

  window.YinweiWorkspace = {
    applySceneSnapshot: applySceneSnapshot,
    applyPlaybackTelemetry: applyPlaybackTelemetry,
    applyUiState: applyUiState,
    init: function () {
      postToHost({ type: 'ready' });
    },
  };

  formatPose();
  renderer.render(scene, camera);
  postToHost({
    type: 'ready',
    width: window.innerWidth,
    height: window.innerHeight,
  });
})();
