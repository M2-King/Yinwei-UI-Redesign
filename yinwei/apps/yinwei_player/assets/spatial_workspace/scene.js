/* Yinwei spatial workspace — Three.js r160, professional listening room.
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
  var FLOOR_Y = -1.18;
  var FLOOR_SIZE = 16;
  var MAX_DPR = 1.5;
  var POSE_MS = 32;
  var CAM_FAR = 160;

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
  var viewTween = null;
  var objectsById = {};
  var authoritativeRevision = 0;
  var selectedObjectId = null;
  var hoveredObjectId = null;
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
  scene.background = new THREE.Color(0x0a0a0c);
  scene.fog = new THREE.Fog(0x0a0a0c, 18, 48);

  var camera = new THREE.PerspectiveCamera(40, 1, 0.08, CAM_FAR);
  var camSph = new THREE.Spherical(5.4, 1.28, -0.58);
  var camSphGoal = camSph.clone();
  var camTarget = new THREE.Vector3(0, 0.18, -0.35);
  var camTargetGoal = camTarget.clone();
  var camDamp = 0.16;

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
  renderer.setClearColor(0x0a0a0c, 1);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.shadowMap.enabled = false;
  document.body.appendChild(renderer.domElement);
  if (!renderer.getContext()) {
    document.getElementById('hint').textContent = 'WebGL context missing';
  }

  function capDpr() {
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, MAX_DPR));
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

  scene.add(new THREE.HemisphereLight(0xd0d4dc, 0x222226, 1.05));
  var key = new THREE.DirectionalLight(0xf7f7fa, 0.95);
  key.position.set(2.4, 6.2, 3.4);
  scene.add(key);
  var rim = new THREE.DirectionalLight(0xc5d0dc, 0.32);
  rim.position.set(-2.6, 2.2, -3.2);
  scene.add(rim);
  scene.add(new THREE.AmbientLight(0x404048, 0.35));

  var geo = {
    floor: new THREE.PlaneGeometry(FLOOR_SIZE, FLOOR_SIZE),
    shadow: new THREE.CircleGeometry(0.18, 28),
    ring: new THREE.RingGeometry(0.96, 1.0, 64),
    halo: new THREE.RingGeometry(0.16, 0.185, 48),
    sourceCore: new THREE.SphereGeometry(0.09, 24, 18),
    sourceShell: new THREE.SphereGeometry(0.15, 28, 20),
    sourceHit: new THREE.SphereGeometry(0.48, 16, 12),
    sourceField: new THREE.TorusGeometry(0.24, 0.005, 8, 48),
    handleStem: new THREE.CylinderGeometry(0.01, 0.01, 0.34, 8),
    handleKnob: new THREE.SphereGeometry(0.038, 14, 10),
    head: new THREE.SphereGeometry(0.14, 22, 16),
    ear: new THREE.SphereGeometry(0.032, 10, 8),
    nose: new THREE.ConeGeometry(0.032, 0.08, 8),
    shoulder: new THREE.SphereGeometry(0.1, 14, 10),
    torso: new THREE.CylinderGeometry(0.13, 0.18, 0.48, 18),
    cabinet: new THREE.BoxGeometry(0.24, 0.38, 0.18),
    baffle: new THREE.BoxGeometry(0.22, 0.36, 0.014),
    woofer: new THREE.CylinderGeometry(0.065, 0.065, 0.018, 20),
    tweeter: new THREE.CylinderGeometry(0.026, 0.026, 0.014, 14),
    stand: new THREE.CylinderGeometry(0.02, 0.032, 0.26, 10),
    base: new THREE.CylinderGeometry(0.08, 0.08, 0.022, 12),
  };

  var mat = {
    floor: new THREE.MeshStandardMaterial({
      color: 0x141416,
      roughness: 0.92,
      metalness: 0.04,
    }),
    depth: new THREE.MeshStandardMaterial({
      color: 0x16161a,
      roughness: 1,
      metalness: 0,
    }),
    listener: new THREE.MeshStandardMaterial({
      color: 0xd8d8de,
      roughness: 0.42,
      metalness: 0.18,
    }),
    speaker: new THREE.MeshStandardMaterial({
      color: 0x3a3a40,
      roughness: 0.48,
      metalness: 0.22,
    }),
    baffle: new THREE.MeshStandardMaterial({
      color: 0x2c2c30,
      roughness: 0.62,
      metalness: 0.08,
    }),
    driver: new THREE.MeshStandardMaterial({
      color: 0x6a6a70,
      roughness: 0.35,
      metalness: 0.28,
    }),
    sourceCore: new THREE.MeshStandardMaterial({
      color: 0xe8eef4,
      emissive: 0x8fb4d0,
      emissiveIntensity: 0.42,
      roughness: 0.28,
      metalness: 0.12,
    }),
    sourceShell: new THREE.MeshStandardMaterial({
      color: 0xb9c8d6,
      emissive: 0x4a6a82,
      emissiveIntensity: 0.08,
      roughness: 0.18,
      metalness: 0.34,
      transparent: true,
      opacity: 0.42,
    }),
    field: new THREE.MeshBasicMaterial({
      color: 0xc5d4e2,
      transparent: true,
      opacity: 0.22,
      depthWrite: false,
    }),
    handle: new THREE.MeshStandardMaterial({
      color: 0xcecfd4,
      roughness: 0.4,
      metalness: 0.2,
    }),
    shadow: new THREE.MeshBasicMaterial({
      color: 0x000000,
      transparent: true,
      opacity: 0.28,
      depthWrite: false,
    }),
    halo: new THREE.MeshBasicMaterial({
      color: 0xdfe6ee,
      transparent: true,
      opacity: 0.0,
      side: THREE.DoubleSide,
      depthWrite: false,
    }),
    relation: new THREE.LineBasicMaterial({
      color: 0xa8b8c8,
      transparent: true,
      opacity: 0.28,
    }),
    drop: new THREE.LineDashedMaterial({
      color: 0x6a6a72,
      transparent: true,
      opacity: 0.32,
      dashSize: 0.05,
      gapSize: 0.04,
    }),
    wave: new THREE.MeshBasicMaterial({
      color: 0xb7c9d8,
      transparent: true,
      opacity: 0,
      side: THREE.DoubleSide,
      depthWrite: false,
    }),
  };

  function makeLabelSprite(text, scale) {
    var c = document.createElement('canvas');
    c.width = 256;
    c.height = 64;
    var ctx = c.getContext('2d');
    ctx.clearRect(0, 0, 256, 64);
    ctx.fillStyle = 'rgba(245,245,247,0.55)';
    ctx.font = '600 28px "SF Pro Text", "Segoe UI", sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, 128, 34);
    var tex = new THREE.CanvasTexture(c);
    tex.colorSpace = THREE.SRGBColorSpace;
    var sprite = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: tex,
        transparent: true,
        depthTest: false,
        depthWrite: false,
      })
    );
    sprite.scale.set(scale || 1.15, (scale || 1.15) * 0.25, 1);
    sprite.renderOrder = 2;
    return sprite;
  }

  function buildRoom() {
    var g = new THREE.Group();
    var floor = new THREE.Mesh(geo.floor, mat.floor);
    floor.rotation.x = -Math.PI / 2;
    floor.position.y = FLOOR_Y;
    g.add(floor);

    var grid = new THREE.GridHelper(FLOOR_SIZE, 32, 0x2a2a30, 0x1a1a1e);
    grid.position.y = FLOOR_Y + 0.003;
    var gm = grid.material;
    (Array.isArray(gm) ? gm : [gm]).forEach(function (m) {
      m.transparent = true;
      m.opacity = 0.22;
    });
    g.add(grid);

    var back = new THREE.Mesh(new THREE.PlaneGeometry(FLOOR_SIZE, 4.6), mat.depth);
    back.position.set(0, FLOOR_Y + 2.3, FLOOR_SIZE * 0.48);
    g.add(back);

    var axisMat = new THREE.LineBasicMaterial({
      color: 0x3a3a42,
      transparent: true,
      opacity: 0.35,
    });
    g.add(
      new THREE.Line(
        new THREE.BufferGeometry().setFromPoints([
          new THREE.Vector3(-2.6, FLOOR_Y + 0.01, 0),
          new THREE.Vector3(2.6, FLOOR_Y + 0.01, 0),
        ]),
        axisMat
      )
    );
    g.add(
      new THREE.Line(
        new THREE.BufferGeometry().setFromPoints([
          new THREE.Vector3(0, FLOOR_Y + 0.01, -2.6),
          new THREE.Vector3(0, FLOOR_Y + 0.01, 2.6),
        ]),
        axisMat
      )
    );

    var ringMat = new THREE.MeshBasicMaterial({
      color: 0x2e2e34,
      transparent: true,
      opacity: 0.35,
      side: THREE.DoubleSide,
      depthWrite: false,
    });
    [1, 2, 3.2].forEach(function (r) {
      var ring = new THREE.Mesh(geo.ring, ringMat);
      ring.rotation.x = -Math.PI / 2;
      ring.position.y = FLOOR_Y + 0.008;
      ring.scale.setScalar(r);
      g.add(ring);
    });

    var front = makeLabelSprite('FRONT', 1.4);
    front.position.set(0, FLOOR_Y + 0.04, -3.35);
    var right = makeLabelSprite('RIGHT', 1.2);
    right.position.set(3.35, FLOOR_Y + 0.04, 0);
    var left = makeLabelSprite('LEFT', 1.2);
    left.position.set(-3.35, FLOOR_Y + 0.04, 0);
    var rear = makeLabelSprite('REAR', 1.2);
    rear.position.set(0, FLOOR_Y + 0.04, 3.35);
    g.add(front, right, left, rear);

    scene.add(g);
  }
  buildRoom();

  function makeListenerMesh() {
    var g = new THREE.Group();
    var head = new THREE.Mesh(geo.head, mat.listener);
    head.scale.set(0.9, 1.05, 0.94);
    var earL = new THREE.Mesh(geo.ear, mat.listener);
    earL.position.set(-0.12, 0.01, 0);
    var earR = earL.clone();
    earR.position.x = 0.12;
    var nose = new THREE.Mesh(geo.nose, mat.listener);
    nose.rotation.x = -Math.PI / 2;
    nose.position.set(0, -0.01, -0.13);
    var torso = new THREE.Mesh(geo.torso, mat.listener);
    torso.position.y = -0.38;
    var shL = new THREE.Mesh(geo.shoulder, mat.listener);
    shL.position.set(-0.14, -0.2, 0);
    var shR = shL.clone();
    shR.position.x = 0.14;
    g.add(head, earL, earR, nose, torso, shL, shR);
    g.userData.kind = 'listener';
    return g;
  }

  function makeEmitterMesh(obj) {
    var g = new THREE.Group();
    var body = new THREE.Mesh(geo.cabinet, mat.speaker);
    var baffle = new THREE.Mesh(geo.baffle, mat.baffle);
    baffle.position.z = 0.086;
    var woofer = new THREE.Mesh(geo.woofer, mat.driver);
    woofer.rotation.x = Math.PI / 2;
    woofer.position.set(0, -0.04, 0.095);
    var tweeter = new THREE.Mesh(geo.tweeter, mat.driver);
    tweeter.rotation.x = Math.PI / 2;
    tweeter.position.set(0, 0.08, 0.094);
    var stand = new THREE.Mesh(geo.stand, mat.speaker);
    stand.position.y = -0.27;
    var base = new THREE.Mesh(geo.base, mat.speaker);
    base.position.y = -0.39;
    g.add(body, baffle, woofer, tweeter, stand, base);
    g.userData.kind = 'emitter';
    g.userData.body = body;
    g.userData.visualRole = obj && obj.visualRole;
    var role = (obj && obj.visualRole) || '';
    if (role) {
      var tag = makeLabelSprite(String(role), 0.7);
      tag.position.y = 0.28;
      tag.visible = false;
      g.add(tag);
      g.userData.label = tag;
    }
    return g;
  }

  function makeSourceMesh() {
    var g = new THREE.Group();
    var core = new THREE.Mesh(geo.sourceCore, mat.sourceCore);
    var shell = new THREE.Mesh(geo.sourceShell, mat.sourceShell);
    var field = new THREE.Mesh(geo.sourceField, mat.field);
    field.rotation.x = Math.PI / 2;
    var hit = new THREE.Mesh(
      geo.sourceHit,
      new THREE.MeshBasicMaterial({ visible: false })
    );
    var stem = new THREE.Mesh(geo.handleStem, mat.handle);
    stem.position.y = 0.28;
    var knob = new THREE.Mesh(geo.handleKnob, mat.handle);
    knob.position.y = 0.46;
    stem.userData.elevationHandle = true;
    knob.userData.elevationHandle = true;
    g.add(core, shell, field, hit, stem, knob);
    g.userData.kind = 'source';
    g.userData.visual = core;
    return g;
  }

  var contactShadow = new THREE.Mesh(geo.shadow, mat.shadow);
  contactShadow.rotation.x = -Math.PI / 2;
  contactShadow.position.y = FLOOR_Y + 0.01;
  scene.add(contactShadow);

  var selectionHalo = new THREE.Mesh(geo.halo, mat.halo);
  selectionHalo.rotation.x = -Math.PI / 2;
  selectionHalo.position.y = FLOOR_Y + 0.012;
  selectionHalo.visible = false;
  scene.add(selectionHalo);

  var relationLine = new THREE.Line(
    new THREE.BufferGeometry().setFromPoints([
      new THREE.Vector3(),
      new THREE.Vector3(),
    ]),
    mat.relation
  );
  scene.add(relationLine);

  var dropLine = new THREE.Line(
    new THREE.BufferGeometry().setFromPoints([
      new THREE.Vector3(),
      new THREE.Vector3(),
    ]),
    mat.drop
  );
  scene.add(dropLine);

  var waveGroup = new THREE.Group();
  scene.add(waveGroup);
  var waves = [];
  function makeWave() {
    var mesh = new THREE.Mesh(new THREE.RingGeometry(0.18, 0.2, 48), mat.wave.clone());
    mesh.userData.age = 999;
    waveGroup.add(mesh);
    waves.push(mesh);
  }
  for (var wi = 0; wi < 4; wi++) makeWave();

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
    if (!mesh) {
      contactShadow.visible = false;
      relationLine.visible = false;
      dropLine.visible = false;
      return;
    }
    contactShadow.visible = true;
    contactShadow.position.set(mesh.position.x, FLOOR_Y + 0.01, mesh.position.z);
    var lift = Math.max(0.02, mesh.position.y - FLOOR_Y);
    var s = 0.7 + Math.min(1.4, lift * 0.18);
    contactShadow.scale.set(s, s, s);
    mat.shadow.opacity = 0.32 / (1 + lift * 0.35);
    mat.sourceCore.emissiveIntensity = state.active ? 0.36 + state.envelopment * 0.16 : 0.12;

    var ear = listener ? listener.position : new THREE.Vector3();
    relationLine.visible = true;
    relationLine.geometry.dispose();
    relationLine.geometry = new THREE.BufferGeometry().setFromPoints([
      ear.clone(),
      mesh.position.clone(),
    ]);

    dropLine.visible = true;
    dropLine.geometry.dispose();
    dropLine.geometry = new THREE.BufferGeometry().setFromPoints([
      mesh.position.clone(),
      new THREE.Vector3(mesh.position.x, FLOOR_Y + 0.02, mesh.position.z),
    ]);
    dropLine.computeLineDistances();
  }

  function formatPose() {
    var el = document.getElementById('pose');
    if (!source) {
      el.innerHTML = '<span>Az</span>—  <span>El</span>—  <span>Dist</span>—';
      return;
    }
    var pose = xyzToPose(source.position);
    el.innerHTML =
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
      selectionHalo.visible = false;
      return;
    }
    var kind = mesh.userData.kind;
    var pose = xyzToPose(mesh.position);
    var xyz = mesh.position;
    var title =
      kind === 'source'
        ? 'SOURCE'
        : kind === 'listener'
          ? 'LISTENER'
          : String(mesh.userData.visualRole || mesh.userData.id || 'EMITTER').toUpperCase();
    var note =
      kind === 'emitter'
        ? 'visual layout · not acoustic Array'
        : kind === 'source'
          ? 'Point source · Flutter owns scene'
          : 'listener-0';
    el.style.display = 'block';
    el.innerHTML =
      '<div class="ch">' +
      title +
      '</div><div class="muted">' +
      note +
      '</div>' +
      '<div>X ' +
      xyz.x.toFixed(2) +
      ' m &nbsp; Y ' +
      xyz.y.toFixed(2) +
      ' m &nbsp; Z ' +
      xyz.z.toFixed(2) +
      ' m</div>' +
      '<div class="muted">Az ' +
      Math.round(pose.azimuth) +
      '° · El ' +
      Math.round(pose.elevation) +
      '° · Dist ' +
      pose.distance.toFixed(2) +
      ' m</div>';
    selectionHalo.visible = true;
    selectionHalo.position.set(mesh.position.x, FLOOR_Y + 0.014, mesh.position.z);
    var hs = kind === 'source' ? 1.15 : kind === 'listener' ? 1.35 : 0.85;
    selectionHalo.scale.setScalar(hs);
    mat.halo.opacity = 0.55;
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
      if (mesh.userData.label) {
        mesh.userData.label.visible =
          selectedObjectId === obj.id || hoveredObjectId === obj.id;
      }
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
    if (!isFinite(source.position.x) || !isFinite(source.position.y) || !isFinite(source.position.z)) {
      return;
    }
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
  var _dir = new THREE.Vector3();
  var _right = new THREE.Vector3();

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

  function resolveHit(object) {
    var obj = object;
    var elevation = false;
    while (obj) {
      if (obj.userData && obj.userData.elevationHandle) elevation = true;
      if (obj.userData && obj.userData.kind) {
        return { mesh: obj, elevationHandle: elevation };
      }
      obj = obj.parent;
    }
    return null;
  }

  function pick(ev) {
    ndcFromEvent(ev);
    raycaster.setFromCamera(pointer, camera);
    var hits = raycaster.intersectObjects(pickableMeshes(), true);
    if (!hits.length) return null;
    var closest = null;
    var closestVisible = null;
    for (var i = 0; i < hits.length; i++) {
      var resolved = resolveHit(hits[i].object);
      if (!resolved) continue;
      if (resolved.elevationHandle) return resolved;
      if (!closest) closest = resolved;
      var mat = hits[i].object.material;
      var vis =
        hits[i].object.visible !== false &&
        !(mat && mat.visible === false);
      if (vis && !closestVisible) closestVisible = resolved;
    }
    // Invisible source hit-sphere is a grab aid only. Visible listener /
    // emitter meshes win when they lie on the same ray.
    return closestVisible || closest;
  }

  function selectResolved(resolved) {
    if (!resolved) {
      selectedObjectId = null;
      postToHost({ type: 'selectObject', objectId: null });
      showSelectionHud(null);
      return;
    }
    selectedObjectId = resolved.mesh.userData.id;
    postToHost({ type: 'selectObject', objectId: selectedObjectId });
    showSelectionHud(resolved.mesh);
  }

  renderer.domElement.addEventListener('contextmenu', function (e) {
    e.preventDefault();
  });

  renderer.domElement.addEventListener('pointerdown', function (e) {
    ndcFromEvent(e);
    lastPtr.x = e.clientX;
    lastPtr.y = e.clientY;
    var resolved = pick(e);
    if (e.button === 0 && resolved && resolved.mesh.userData.kind === 'source') {
      dragging = {
        kind: 'source',
        objectId: resolved.mesh.userData.id,
        mode: resolved.elevationHandle || e.shiftKey ? 'y' : 'xz',
      };
      if (dragging.mode === 'y') {
        camera.getWorldDirection(_dir);
        _right.crossVectors(_dir, camera.up).normalize();
        dragPlane.setFromNormalAndCoplanarPoint(_right, resolved.mesh.position);
      } else {
        dragPlane.setFromNormalAndCoplanarPoint(
          new THREE.Vector3(0, 1, 0),
          resolved.mesh.position
        );
      }
      selectResolved(resolved);
      try {
        renderer.domElement.setPointerCapture(e.pointerId);
      } catch (err) {}
      return;
    }
    if (e.button === 0 && resolved && resolved.mesh.userData.kind === 'emitter') {
      selectResolved(resolved);
      try {
        renderer.domElement.setPointerCapture(e.pointerId);
      } catch (err) {}
      return;
    }
    if (e.button === 2 || e.button === 1) {
      panningCam = true;
    } else if (e.button === 0 && viewMode === 'free') {
      orbitingCam = true;
    }
    selectResolved(resolved);
    try {
      renderer.domElement.setPointerCapture(e.pointerId);
    } catch (err) {}
  });

  renderer.domElement.addEventListener('pointermove', function (e) {
    var dx = e.clientX - lastPtr.x;
    var dy = e.clientY - lastPtr.y;
    lastPtr.x = e.clientX;
    lastPtr.y = e.clientY;
    if (dragging && dragging.kind === 'source' && source) {
      ndcFromEvent(e);
      raycaster.setFromCamera(pointer, camera);
      if (e.shiftKey) dragging.mode = 'y';
      if (dragging.mode === 'y') {
        camera.getWorldDirection(_dir);
        _right.crossVectors(_dir, camera.up).normalize();
        dragPlane.setFromNormalAndCoplanarPoint(_right, source.position);
      }
      if (raycaster.ray.intersectPlane(dragPlane, dragHit)) {
        if (dragging.mode === 'y') {
          source.position.y = dragHit.y;
        } else {
          source.position.x = dragHit.x;
          source.position.z = dragHit.z;
        }
        decorateSourceVisual(source);
        formatPose();
        showSelectionHud(source);
        postSourceIntent('sourcePosePreview', false);
        needsRender = true;
      }
      return;
    }
    if (!dragging) {
      var hover = pick(e);
      var nextHover = hover ? hover.mesh.userData.id : null;
      if (nextHover !== hoveredObjectId) {
        hoveredObjectId = nextHover;
        Object.keys(objectsById).forEach(function (id) {
          var mesh = objectsById[id];
          if (mesh.userData.label) {
            mesh.userData.label.visible =
              selectedObjectId === id || hoveredObjectId === id;
          }
        });
        renderer.domElement.style.cursor = hover ? 'pointer' : 'default';
        needsRender = true;
      }
    }
    if (orbitingCam && viewMode === 'free') {
      camSphGoal.theta -= dx * 0.005;
      camSphGoal.phi = THREE.MathUtils.clamp(
        camSphGoal.phi + dy * 0.005,
        0.12,
        Math.PI - 0.18
      );
      needsRender = true;
    }
    if (panningCam) {
      camera.getWorldDirection(_dir);
      _right.crossVectors(_dir, camera.up).normalize();
      camTargetGoal.addScaledVector(_right, -dx * 0.004 * camSphGoal.radius);
      camTargetGoal.addScaledVector(camera.up, dy * 0.004 * camSphGoal.radius);
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
        var next = Math.max(0.05, len + (e.deltaY > 0 ? 0.12 : -0.12));
        source.position.setLength(next);
        decorateSourceVisual(source);
        formatPose();
        postSourceIntent('sourcePosePreview', false);
        needsRender = true;
        return;
      }
      camSphGoal.radius = THREE.MathUtils.clamp(
        camSphGoal.radius * (e.deltaY > 0 ? 1.07 : 0.93),
        1.4,
        80
      );
      needsRender = true;
    },
    { passive: false }
  );

  var VIEW = {
    free: { radius: 5.4, phi: 1.28, theta: -0.58, target: new THREE.Vector3(0, 0.18, -0.35) },
    top: { radius: 8.4, phi: 0.12, theta: 0, target: new THREE.Vector3(0, 0, 0) },
    front: { radius: 5.8, phi: 1.48, theta: 0, target: new THREE.Vector3(0, 0.2, 0) },
    listener: { radius: 1.35, phi: 1.48, theta: 0, target: new THREE.Vector3(0, 0.08, -1.6) },
  };

  function fitCamera() {
    var box = new THREE.Box3();
    var has = false;
    Object.keys(objectsById).forEach(function (id) {
      box.expandByObject(objectsById[id]);
      has = true;
    });
    if (!has) return VIEW.free;
    var size = box.getSize(new THREE.Vector3());
    var center = box.getCenter(new THREE.Vector3());
    return {
      radius: THREE.MathUtils.clamp(size.length() * 0.72, 3.4, 18),
      phi: 1.26,
      theta: -0.48,
      target: center,
    };
  }

  function listenerView() {
    var origin = listener ? listener.position.clone() : new THREE.Vector3();
    return {
      radius: 1.45,
      phi: 1.48,
      theta: 0,
      target: origin.clone().add(new THREE.Vector3(0, 0.06, -1.8)),
    };
  }

  function setView(name) {
    viewMode = name === 'fit' ? 'free' : name;
    var v = name === 'fit' ? fitCamera() : name === 'listener' ? listenerView() : VIEW[name] || VIEW.free;
    viewTween = {
      t0: performance.now(),
      dur: 420,
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
      if (waves[i].userData.age > 1.4) {
        waves[i].userData.age = 0;
        waves[i].position.copy(source.position);
        waves[i].lookAt(listener ? listener.position : new THREE.Vector3());
        return;
      }
    }
  }

  function updateWaves(dt) {
    var live = state.playing && state.active;
    waveGroup.visible = live;
    if (!live) return;
    waveAcc += dt;
    if (waveAcc >= 0.78 - state.envelopment * 0.16) {
      waveAcc = 0;
      spawnWave();
    }
    waves.forEach(function (w) {
      w.userData.age += dt;
      var t = w.userData.age / 1.45;
      if (t >= 1) {
        w.material.opacity = 0;
        return;
      }
      var sc = 0.35 + t * (1.4 + state.envelopment);
      w.scale.set(sc, sc, sc);
      w.material.opacity = (1 - t) * 0.18;
    });
  }

  var lastT = performance.now();
  function tick(now) {
    requestAnimationFrame(tick);
    var dt = Math.min(0.05, (now - lastT) / 1000);
    lastT = now;

    if (viewTween) {
      var k = Math.min(1, (now - viewTween.t0) / viewTween.dur);
      var ease = 1 - Math.pow(1 - k, 3);
      camSphGoal.radius = viewTween.fromR + (viewTween.toR - viewTween.fromR) * ease;
      camSphGoal.phi = viewTween.fromP + (viewTween.toP - viewTween.fromP) * ease;
      camSphGoal.theta = viewTween.fromT + (viewTween.toT - viewTween.fromT) * ease;
      camTargetGoal.lerpVectors(viewTween.fromTarget, viewTween.toTarget, ease);
      if (k >= 1) viewTween = null;
      needsRender = true;
    }

    var damp = 1 - Math.pow(1 - camDamp, dt * 60);
    if (
      Math.abs(camSph.radius - camSphGoal.radius) > 1e-4 ||
      Math.abs(camSph.phi - camSphGoal.phi) > 1e-4 ||
      Math.abs(camSph.theta - camSphGoal.theta) > 1e-4 ||
      camTarget.distanceToSquared(camTargetGoal) > 1e-6
    ) {
      camSph.radius += (camSphGoal.radius - camSph.radius) * damp;
      camSph.phi += (camSphGoal.phi - camSph.phi) * damp;
      camSph.theta += (camSphGoal.theta - camSph.theta) * damp;
      camTarget.lerp(camTargetGoal, damp);
      placeCamera();
      needsRender = true;
    }

    var animate = (state.playing && state.active) || dragging;
    if (animate) {
      updateWaves(dt);
      if (source) {
        mat.sourceCore.emissiveIntensity =
          0.34 + 0.12 * Math.sin(now * 0.004) + state.envelopment * 0.1;
      }
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

  function clientXY(mesh) {
    var v = new THREE.Vector3();
    mesh.updateWorldMatrix(true, true);
    mesh.getWorldPosition(v);
    v.project(camera);
    var r = renderer.domElement.getBoundingClientRect();
    return {
      x: r.left + (v.x * 0.5 + 0.5) * r.width,
      y: r.top + (-v.y * 0.5 + 0.5) * r.height,
    };
  }

  function firePointer(type, x, y, extra) {
    extra = extra || {};
    renderer.domElement.dispatchEvent(
      new PointerEvent(type, {
        bubbles: true,
        cancelable: true,
        view: window,
        clientX: x,
        clientY: y,
        button: extra.button || 0,
        buttons: extra.buttons != null ? extra.buttons : type === 'pointerup' ? 0 : 1,
        pointerId: 1,
        pointerType: 'mouse',
        isPrimary: true,
        shiftKey: !!extra.shift,
      })
    );
  }

  function debugInspect() {
    return {
      revision: authoritativeRevision,
      viewMode: viewMode,
      selected: selectedObjectId,
      ids: Object.keys(objectsById),
      source: source
        ? { x: source.position.x, y: source.position.y, z: source.position.z }
        : null,
      hasListener: !!listener,
      emitterCount: Object.keys(objectsById).filter(function (id) {
        return objectsById[id].userData.kind === 'emitter';
      }).length,
      camera: {
        theta: camSphGoal.theta,
        phi: camSphGoal.phi,
        radius: camSphGoal.radius,
        target: {
          x: camTargetGoal.x,
          y: camTargetGoal.y,
          z: camTargetGoal.z,
        },
      },
    };
  }

  window.YinweiWorkspace = {
    applySceneSnapshot: applySceneSnapshot,
    applyPlaybackTelemetry: applyPlaybackTelemetry,
    applyUiState: applyUiState,
    init: function () {
      postToHost({ type: 'ready' });
    },
    debug: {
      inspect: debugInspect,
      setView: function (name) {
        setView(name);
        return debugInspect();
      },
      click: function (id) {
        var mesh = objectsById[id];
        if (!mesh) return { ok: false, reason: 'missing', id: id };
        var p = clientXY(mesh);
        firePointer('pointerdown', p.x, p.y, { buttons: 1 });
        firePointer('pointerup', p.x, p.y, { buttons: 0 });
        return { ok: true, id: selectedObjectId, x: p.x, y: p.y };
      },
      dragSource: function (mode, pixels) {
        if (!source) return { ok: false, reason: 'no-source' };
        var p = clientXY(source);
        var shift = mode === 'y';
        var nx = p.x + (shift ? 0 : pixels || 70);
        var ny = p.y + (shift ? -(pixels || 50) : 0);
        firePointer('pointerdown', p.x, p.y, { buttons: 1, shift: shift });
        firePointer('pointermove', nx, ny, { buttons: 1, shift: shift });
        firePointer('pointerup', nx, ny, { buttons: 0, shift: shift });
        return debugInspect();
      },
      orbit: function () {
        var r = renderer.domElement.getBoundingClientRect();
        var x = r.left + r.width * 0.82;
        var y = r.top + r.height * 0.18;
        firePointer('pointerdown', x, y, { buttons: 1 });
        firePointer('pointermove', x + 46, y + 20, { buttons: 1 });
        firePointer('pointerup', x + 46, y + 20, { buttons: 0 });
        return debugInspect();
      },
      pan: function () {
        var r = renderer.domElement.getBoundingClientRect();
        var x = r.left + r.width * 0.72;
        var y = r.top + r.height * 0.28;
        firePointer('pointerdown', x, y, { button: 2, buttons: 2 });
        firePointer('pointermove', x + 28, y + 14, { button: 2, buttons: 2 });
        firePointer('pointerup', x + 28, y + 14, { button: 2, buttons: 0 });
        return debugInspect();
      },
      zoom: function () {
        var before = camSphGoal.radius;
        var r = renderer.domElement.getBoundingClientRect();
        renderer.domElement.dispatchEvent(
          new WheelEvent('wheel', {
            bubbles: true,
            cancelable: true,
            clientX: r.left + r.width * 0.5,
            clientY: r.top + r.height * 0.5,
            deltaY: 240,
          })
        );
        return { before: before, after: camSphGoal.radius };
      },
      capture: function () {
        renderer.render(scene, camera);
        return renderer.domElement.toDataURL('image/png');
      },
    },
  };

  formatPose();
  renderer.render(scene, camera);
  postToHost({
    type: 'ready',
    width: window.innerWidth,
    height: window.innerHeight,
  });

  if (!(window.chrome && window.chrome.webview)) {
    setTimeout(function () {
      if (authoritativeRevision !== 0) return;
      applySceneSnapshot({
        type: 'sceneSnapshot',
        schemaVersion: 1,
        revision: 1,
        scene: {
          schemaVersion: 1,
          revision: 1,
          listener: {
            id: 'listener-0',
            type: 'listener',
            worldPosition: { x: 0, y: 0, z: 0 },
            orientation: { w: 1, x: 0, y: 0, z: 0 },
          },
          sources: [
            {
              id: 'source-main',
              type: 'source',
              worldPosition: { x: 0.85, y: 0.35, z: -1.7 },
            },
          ],
          emitters: [
            { id: 'emitter-FL', type: 'emitter', visualRole: 'FL', worldPosition: { x: -1.2, y: 0, z: -2.1 } },
            { id: 'emitter-FR', type: 'emitter', visualRole: 'FR', worldPosition: { x: 1.2, y: 0, z: -2.1 } },
            { id: 'emitter-C', type: 'emitter', visualRole: 'C', worldPosition: { x: 0, y: 0, z: -2.4 } },
            { id: 'emitter-LFE', type: 'emitter', visualRole: 'LFE', worldPosition: { x: -0.5, y: -0.35, z: -1.6 } },
            { id: 'emitter-SL', type: 'emitter', visualRole: 'SL', worldPosition: { x: -2.0, y: 0, z: 0 } },
            { id: 'emitter-SR', type: 'emitter', visualRole: 'SR', worldPosition: { x: 2.0, y: 0, z: 0 } },
            { id: 'emitter-RL', type: 'emitter', visualRole: 'RL', worldPosition: { x: -1.2, y: 0, z: 2.1 } },
            { id: 'emitter-RR', type: 'emitter', visualRole: 'RR', worldPosition: { x: 1.2, y: 0, z: 2.1 } },
          ],
        },
      });
    }, 40);
  }
})();
