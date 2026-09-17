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
  var FLOOR_SIZE = 18;
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
  var gestureBasedOnRevision = null;
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
  scene.background = new THREE.Color(0x0b0c0e);
  scene.fog = new THREE.Fog(0x121417, 16, 38);

  var camera = new THREE.PerspectiveCamera(38, 1, 0.08, CAM_FAR);
  var camSph = new THREE.Spherical(6.05, 1.12, 0.08);
  var camSphGoal = camSph.clone();
  var camTarget = new THREE.Vector3(0.02, -0.1, -0.22);
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
  renderer.setClearColor(0x0b0c0e, 1);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.32;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.VSMShadowMap;
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

  scene.add(new THREE.HemisphereLight(0xe8e4dc, 0x2e2a26, 0.82));
  var key = new THREE.DirectionalLight(0xf6f2ea, 2.12);
  key.position.set(-1.6, 5.2, 4.4);
  key.castShadow = true;
  key.shadow.mapSize.set(1024, 1024);
  key.shadow.camera.left = -4.4;
  key.shadow.camera.right = 4.4;
  key.shadow.camera.top = 4.4;
  key.shadow.camera.bottom = -4.4;
  key.shadow.camera.near = 0.5;
  key.shadow.camera.far = 16;
  key.shadow.bias = -0.0004;
  key.shadow.normalBias = 0.025;
  key.shadow.radius = 3.5;
  key.shadow.blurSamples = 8;
  scene.add(key);
  var fill = new THREE.DirectionalLight(0xd7dee6, 1.32);
  fill.position.set(3.4, 2.35, 4.8);
  scene.add(fill);
  var rim = new THREE.DirectionalLight(0xeee8dc, 1.08);
  rim.position.set(0.45, 2.7, -4.7);
  scene.add(rim);
  scene.add(new THREE.AmbientLight(0x434044, 0.5));
  var canopy = new THREE.PointLight(0xf4eee4, 1.18, 6.4, 1.8);
  canopy.position.set(0.12, 2.28, 0.08);
  scene.add(canopy);

  // A small, prefiltered studio environment provides broad material highlights.
  // It is baked once; no reflection probes or extra passes run in the frame loop.
  var reflectionStudio = new THREE.Scene();
  reflectionStudio.background = new THREE.Color(0x1c1e22);
  var softboxGeometry = new THREE.PlaneGeometry(1, 1);
  var softboxes = [];
  [[-3.4, 4.2, 3.2, 3.2, 4.6, 0xd6dee8], [3.6, 3.2, 2.6, 2.5, 3.8, 0xd2c8b6],
    [0.2, 6.3, 1.6, 6.4, 2.6, 0xf2eee6]].forEach(function (p) {
    var material = new THREE.MeshBasicMaterial({ color: p[5], side: THREE.DoubleSide });
    var box = new THREE.Mesh(softboxGeometry, material);
    box.position.set(p[0], p[1], p[2]);
    box.scale.set(p[3], p[4], 1);
    box.lookAt(0, 0, 0);
    reflectionStudio.add(box);
    softboxes.push(material);
  });
  var pmrem = new THREE.PMREMGenerator(renderer);
  var studioEnvironment = pmrem.fromScene(reflectionStudio, 0.08, 0.1, 30);
  scene.environment = studioEnvironment.texture;
  pmrem.dispose();
  softboxGeometry.dispose();
  softboxes.forEach(function (material) { material.dispose(); });
  reflectionStudio.clear();

  function roundedCabinet(w, h, d, r) {
    var shape = new THREE.Shape();
    var x = -w / 2 + r, y = -h / 2 + r, bw = w - 2 * r, bh = h - 2 * r;
    shape.moveTo(x, y); shape.lineTo(x + bw, y);
    shape.lineTo(x + bw, y + bh); shape.lineTo(x, y + bh); shape.closePath();
    var geometry = new THREE.ExtrudeGeometry(shape, {
      depth: d - 2 * r, bevelEnabled: true, bevelSegments: 3,
      steps: 1, bevelSize: r, bevelThickness: r,
    });
    geometry.translate(0, 0, -d / 2 + r);
    geometry.computeVertexNormals();
    return geometry;
  }

  // Radiused front corners and rolled edges, instead of a beveled rectangle.
  // The enclosure stays centered on its existing acoustic/selection anchor.
  function monitorEnclosure(w, h, d, radius, bevel) {
    var x = w / 2 - bevel, y = h / 2 - bevel, r = radius;
    var shape = new THREE.Shape();
    shape.moveTo(-x + r, -y);
    shape.lineTo(x - r, -y); shape.quadraticCurveTo(x, -y, x, -y + r);
    shape.lineTo(x, y - r); shape.quadraticCurveTo(x, y, x - r, y);
    shape.lineTo(-x + r, y); shape.quadraticCurveTo(-x, y, -x, y - r);
    shape.lineTo(-x, -y + r); shape.quadraticCurveTo(-x, -y, -x + r, -y);
    var geometry = new THREE.ExtrudeGeometry(shape, {
      depth: d - 2 * bevel, steps: 1, curveSegments: 8,
      bevelEnabled: true, bevelThickness: bevel, bevelSize: bevel, bevelSegments: 6,
    });
    geometry.translate(0, 0, -d / 2 + bevel);
    // ExtrudeGeometry duplicates triangle vertices. Average the side/bevel normals
    // at coincident positions so the rolled edge is continuous, keeping caps flat.
    var positions = geometry.attributes.position;
    var normals = geometry.attributes.normal;
    var sideGroup = geometry.groups[1];
    var edgeNormals = new Map();
    function vertexKey(i) {
      return Math.round(positions.getX(i) * 1e6) + ',' +
        Math.round(positions.getY(i) * 1e6) + ',' + Math.round(positions.getZ(i) * 1e6);
    }
    for (var i = sideGroup.start; i < sideGroup.start + sideGroup.count; i++) {
      var key = vertexKey(i);
      var normal = edgeNormals.get(key) || new THREE.Vector3();
      normal.add(new THREE.Vector3(normals.getX(i), normals.getY(i), normals.getZ(i)));
      edgeNormals.set(key, normal);
    }
    edgeNormals.forEach(function (normal) { normal.normalize(); });
    for (var j = sideGroup.start; j < sideGroup.start + sideGroup.count; j++) {
      var smooth = edgeNormals.get(vertexKey(j));
      normals.setXYZ(j, smooth.x, smooth.y, smooth.z);
    }
    return geometry;
  }

  var geo = {
    floor: new THREE.PlaneGeometry(FLOOR_SIZE, FLOOR_SIZE),
    shadow: new THREE.CircleGeometry(0.18, 28),
    ring: new THREE.RingGeometry(0.98, 1.0, 72),
    halo: new THREE.RingGeometry(0.22, 0.235, 64),
    selection: new THREE.RingGeometry(0.29, 0.305, 64),
    sourceCore: new THREE.SphereGeometry(0.14, 32, 24),
    sourceShell: new THREE.SphereGeometry(0.245, 40, 28),
    sourceHit: new THREE.SphereGeometry(0.52, 18, 14),
    sourceField: new THREE.TorusGeometry(0.33, 0.006, 8, 64),
    sourceBand: new THREE.TorusGeometry(0.255, 0.012, 10, 64),
    handleStem: new THREE.CylinderGeometry(0.009, 0.009, 0.4, 10),
    handleKnob: new THREE.SphereGeometry(0.043, 16, 12),
    forwardFin: new THREE.ConeGeometry(0.075, 0.24, 3),
    cabinet: monitorEnclosure(0.44, 0.65, 0.37, 0.065, 0.018),
    subCabinet: monitorEnclosure(0.56, 0.62, 0.51, 0.045, 0.014),
    baffle: monitorEnclosure(0.405, 0.603, 0.022, 0.059, 0.004),
    subBaffle: monitorEnclosure(0.516, 0.576, 0.022, 0.039, 0.004),
    wooferTrim: new THREE.RingGeometry(0.101, 0.116, 48),
    woofer: new THREE.TorusGeometry(0.088, 0.012, 12, 40),
    cone: new THREE.LatheGeometry([
      new THREE.Vector2(0.079, 0), new THREE.Vector2(0.064, -0.009),
      new THREE.Vector2(0.041, -0.022), new THREE.Vector2(0.024, -0.025),
    ], 40),
    dustCap: new THREE.SphereGeometry(0.031, 20, 16),
    tweeterTrim: new THREE.LatheGeometry([
      new THREE.Vector2(0.065, 0), new THREE.Vector2(0.053, -0.003),
      new THREE.Vector2(0.04, -0.013), new THREE.Vector2(0.023, -0.02),
    ], 40),
    tweeter: new THREE.SphereGeometry(0.026, 24, 16),
    stand: monitorEnclosure(0.085, 0.8, 0.095, 0.019, 0.005),
    base: monitorEnclosure(0.38, 0.035, 0.34, 0.006, 0.006),
    standPlate: roundedCabinet(0.28, 0.026, 0.24, 0.007),
    isolationPad: new THREE.CylinderGeometry(0.027, 0.029, 0.018, 16),
    standCollar: monitorEnclosure(0.13, 0.075, 0.14, 0.026, 0.005),
    rearPlate: monitorEnclosure(0.23, 0.27, 0.012, 0.018, 0.003),
    rearFin: new THREE.BoxGeometry(0.008, 0.13, 0.012),
    driverFastener: new THREE.CylinderGeometry(0.006, 0.006, 0.003, 6),
  };

  var mat = {
    floor: new THREE.MeshStandardMaterial({
      color: 0x3c4044,
      roughness: 0.9,
      metalness: 0.05,
    }),
    depth: new THREE.MeshStandardMaterial({
      color: 0x16161a,
      roughness: 0.94,
      metalness: 0.02,
    }),
    panel: new THREE.MeshStandardMaterial({
      color: 0x97938c,
      roughness: 1.0,
      metalness: 0.0,
    }),
    panelInset: new THREE.MeshStandardMaterial({
      color: 0x141418,
      roughness: 0.96,
      metalness: 0.02,
    }),
    listener: new THREE.MeshStandardMaterial({
      color: 0x8e98a0,
      roughness: 0.3,
      metalness: 0.64,
    }),
    listenerDark: new THREE.MeshStandardMaterial({
      color: 0x3a4248,
      roughness: 0.48,
      metalness: 0.22,
    }),
    speaker: new THREE.MeshStandardMaterial({
      color: 0x6c7074,
      roughness: 0.46,
      metalness: 0.2,
    }),
    baffle: new THREE.MeshStandardMaterial({
      color: 0x3c4146,
      roughness: 0.5,
      metalness: 0.1,
    }),
    driver: new THREE.MeshStandardMaterial({
      color: 0x7c858e,
      roughness: 0.3,
      metalness: 0.7,
    }),
    cone: new THREE.MeshStandardMaterial({
      color: 0x2a2e32,
      roughness: 0.62,
      metalness: 0.04,
    }),
    chassis: new THREE.MeshStandardMaterial({
      color: 0x4a5056, roughness: 0.42, metalness: 0.58,
    }),
    rubber: new THREE.MeshStandardMaterial({
      color: 0x101214, roughness: 0.94, metalness: 0,
    }),
    sourceCore: new THREE.MeshStandardMaterial({
      color: 0xfff8ea,
      emissive: 0xd9e7f2,
      emissiveIntensity: 0.5,
      roughness: 0.16,
      metalness: 0.42,
    }),
    sourceShell: new THREE.ShaderMaterial({
      uniforms: { tint: { value: new THREE.Color(0x93c7fa) } },
      vertexShader: 'varying vec3 n; varying vec3 v; void main(){ vec4 p=modelViewMatrix*vec4(position,1.0); n=normalize(normalMatrix*normal); v=normalize(-p.xyz); gl_Position=projectionMatrix*p; }',
      fragmentShader: 'uniform vec3 tint; varying vec3 n; varying vec3 v; void main(){ float rim=pow(1.0-abs(dot(normalize(n),normalize(v))),3.0); gl_FragColor=vec4(tint,0.06+rim*0.8); }',
      transparent: true,
      depthWrite: false,
    }),
    field: new THREE.MeshBasicMaterial({
      color: 0xa8c8e0,
      transparent: true,
      opacity: 0.2,
      depthWrite: false,
    }),
    handle: new THREE.MeshStandardMaterial({
      color: 0xd9e0e7,
      roughness: 0.4,
      metalness: 0.2,
    }),
    shadow: new THREE.MeshBasicMaterial({
      color: 0x000000,
      transparent: true,
      opacity: 0.34,
      depthWrite: false,
    }),
    halo: new THREE.MeshBasicMaterial({
      color: 0xb7cde0,
      transparent: true,
      opacity: 0.0,
      side: THREE.DoubleSide,
      depthWrite: false,
    }),
    selection: new THREE.MeshBasicMaterial({
      color: 0xe0ebf2,
      transparent: true,
      opacity: 0.58,
      side: THREE.DoubleSide,
      depthWrite: false,
    }),
    relation: new THREE.LineBasicMaterial({
      color: 0x9bb7cc,
      transparent: true,
      opacity: 0.26,
    }),
    drop: new THREE.LineDashedMaterial({
      color: 0x6a6a72,
      transparent: true,
      opacity: 0.32,
      dashSize: 0.05,
      gapSize: 0.04,
    }),
    wave: new THREE.MeshBasicMaterial({
      color: 0x9dbdd5,
      transparent: true,
      opacity: 0,
      side: THREE.DoubleSide,
      depthWrite: false,
    }),
  };

  Object.keys(mat).forEach(function (name) {
    if (mat[name].isMeshStandardMaterial) mat[name].envMapIntensity = 0.62;
  });
  mat.floor.envMapIntensity = 0.16;
  mat.listener.envMapIntensity = 1.05;
  mat.listenerDark.envMapIntensity = 0.85;
  mat.speaker.envMapIntensity = 0.74;
  mat.baffle.envMapIntensity = 0.42;
  mat.driver.envMapIntensity = 0.88;
  mat.chassis.envMapIntensity = 0.8;

  // Tileable, deterministic albedo / roughness / relief maps. Different spatial
  // frequencies matter here: cloth weave, mineral aggregate and powder coating
  // should not all read as the same fine noise. Generated once, shared thereafter.
  function studioSurface(kind, repeat) {
    var size = 512;
    function hash(x, y) {
      var n = Math.imul(x + 19, 374761393) ^ Math.imul(y + 71, 668265263);
      n = Math.imul(n ^ (n >>> 13), 1274126177);
      return ((n ^ (n >>> 16)) >>> 0) / 4294967295;
    }
    function noise(x, y, cell) {
      var count = size / cell;
      var ix = Math.floor(x / cell), iy = Math.floor(y / cell);
      var u = x / cell - ix, v = y / cell - iy;
      u = u * u * (3 - 2 * u); v = v * v * (3 - 2 * v);
      var a = hash(ix % count, iy % count), b = hash((ix + 1) % count, iy % count);
      var c = hash(ix % count, (iy + 1) % count), d = hash((ix + 1) % count, (iy + 1) % count);
      return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v - 0.5;
    }
    var contexts = [], pixels = [];
    for (var m = 0; m < 3; m++) {
      var canvas = document.createElement('canvas');
      canvas.width = canvas.height = size;
      var context = canvas.getContext('2d');
      contexts.push(context); pixels.push(context.createImageData(size, size));
    }
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        var grain = hash(x, y) - 0.5;
        var broad = noise(x, y, 64), medium = noise(x, y, 16);
        var albedo, relief, roughness;
        if (kind === 'fabric') {
          var warp = Math.cos(x * Math.PI / 2) * 0.5;
          var weft = Math.cos(y * Math.PI / 2 + (Math.floor(x / 4) % 2) * Math.PI) * 0.5;
          var yarn = warp + weft;
          albedo = 128 + broad * 4 + medium * 3 + yarn * 4 + grain * 7;
          relief = 128 + yarn * 16 + grain * 10;
          roughness = 235 + grain * 16;
        } else if (kind === 'mineral') {
          albedo = 126 + broad * 9 + medium * 6 + grain * 6;
          relief = 128 + medium * 25 + grain * 18;
          roughness = 228 + broad * 22 + grain * 9;
        } else {
          albedo = 198 + broad * 3 + grain * 5;
          relief = 128 + grain * 28;
          roughness = 219 + grain * 20;
        }
        var values = [albedo, roughness, relief];
        var offset = (y * size + x) * 4;
        for (var channel = 0; channel < 3; channel++) {
          var data = pixels[channel].data;
          data[offset] = data[offset + 1] = data[offset + 2] = values[channel];
          data[offset + 3] = 255;
        }
      }
    }
    return contexts.map(function (context, index) {
      context.putImageData(pixels[index], 0, 0);
      var texture = new THREE.CanvasTexture(context.canvas);
      texture.wrapS = texture.wrapT = THREE.RepeatWrapping;
      texture.repeat.set(repeat, repeat);
      texture.anisotropy = Math.min(4, renderer.capabilities.getMaxAnisotropy());
      if (index === 0) texture.colorSpace = THREE.SRGBColorSpace;
      return texture;
    });
  }
  function applySurface(material, maps, relief) {
    material.map = maps[0];
    material.roughnessMap = maps[1];
    material.bumpMap = maps[2];
    material.bumpScale = relief;
  }
  applySurface(mat.panel, studioSurface('fabric', 1), 0.004);
  applySurface(mat.floor, studioSurface('mineral', 9), 0.008);
  applySurface(mat.speaker, studioSurface('coating', 1), 0.0012);
  mat.panel.envMapIntensity = 0.22;
  mat.floor.envMapIntensity = 0.16;
  var wallFabrics = [0x97938c, 0x908c86, 0x9d9891].map(function (color) {
    var material = mat.panel.clone();
    material.color.setHex(color);
    return material;
  });
  var slatMaterial = new THREE.MeshStandardMaterial({
    color: 0x3c3b37, roughness: 0.62, metalness: 0.1, envMapIntensity: 0.34,
  });
  var shadowCanvas = document.createElement('canvas');
  shadowCanvas.width = shadowCanvas.height = 64;
  var shadowContext = shadowCanvas.getContext('2d');
  var shadowFalloff = shadowContext.createRadialGradient(32, 32, 0, 32, 32, 32);
  shadowFalloff.addColorStop(0, '#ffffff');
  shadowFalloff.addColorStop(0.3, '#b0b0b0');
  shadowFalloff.addColorStop(1, '#000000');
  shadowContext.fillStyle = shadowFalloff;
  shadowContext.fillRect(0, 0, 64, 64);
  mat.shadow.alphaMap = new THREE.CanvasTexture(shadowCanvas);

  function makeLabelSprite(text, scale, color, alpha) {
    var c = document.createElement('canvas');
    c.width = 256;
    c.height = 64;
    var ctx = c.getContext('2d');
    ctx.clearRect(0, 0, 256, 64);
    ctx.fillStyle = color || 'rgba(220,230,240,' + (alpha == null ? 0.62 : alpha) + ')';
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

  // Visual room only: metres, +X right, +Y up, -Z front. The listener's
  // ear origin and all host-owned transforms are unchanged; the floor is at -1.18m.
  function buildRoom() {
    var g = new THREE.Group();
    var floor = new THREE.Mesh(geo.floor, mat.floor);
    floor.rotation.x = -Math.PI / 2;
    floor.position.y = FLOOR_Y;
    floor.receiveShadow = true;
    g.add(floor);
    var grid = new THREE.GridHelper(FLOOR_SIZE, 36, 0x777c82, 0x777c82);
    grid.position.y = FLOOR_Y + 0.006;
    grid.material.transparent = true;
    grid.material.opacity = 0.05;
    g.add(grid);

    var rear = new THREE.Mesh(new THREE.BoxGeometry(9.2, 5.2, 0.16), mat.depth);
    rear.position.set(0, FLOOR_Y + 2.6, -4.8);
    g.add(rear);
    var wall = new THREE.Mesh(new THREE.BoxGeometry(0.15, 5.2, 12), mat.panelInset);
    wall.position.set(-4.55, FLOOR_Y + 2.6, 1.2);
    var right = wall.clone(); right.position.x = 4.55;
    g.add(wall, right);

    // Staggered acoustic panels and recessed warm coves give the room scale.
    var panelGeometry = roundedCabinet(1.25, 1.24, 0.13, 0.018);
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 7; col++) {
        var panel = new THREE.Mesh(panelGeometry, wallFabrics[(col + row * 2) % wallFabrics.length]);
        panel.position.set((col - 3) * 1.28, FLOOR_Y + 0.64 + row * 1.28, -4.64);
        panel.receiveShadow = true;
        g.add(panel);
      }
    }
    var trim = new THREE.MeshBasicMaterial({color: 0xdac6a7});
    var cove = new THREE.Mesh(new THREE.BoxGeometry(8.9, 0.016, 0.026), trim);
    cove.position.set(0, FLOOR_Y + 1.29, -4.54);
    g.add(cove);
    [-1, 1].forEach(function(side) {
      var rail = new THREE.Mesh(new THREE.BoxGeometry(0.025, 0.018, 8.2), trim);
      rail.position.set(side * 4.44, FLOOR_Y + 0.03, -0.45);
      g.add(rail);
      for(var i=0; i<30; i++) {
        var slat = new THREE.Mesh(new THREE.BoxGeometry(0.14, 3.8, 0.05), slatMaterial);
        slat.position.set(side * 4.4, FLOOR_Y + 1.9, -4.3 + i * 0.27);
        g.add(slat);
      }
      [-3.6, 0.0, 3.0].forEach(function(z) {
        var wash = new THREE.PointLight(0xffdfb4, 0.72, 3.8, 2);
        wash.position.set(side * 4.1, FLOOR_Y + 0.3, z);
        g.add(wash);
      });
      var rearWash = new THREE.PointLight(0xffdfba, 1.85, 4.6, 2);
      rearWash.position.set(side * 2.8, FLOOR_Y + 1.45, -4.05);
      g.add(rearWash);
    });
    var ringMaterial = new THREE.MeshBasicMaterial({
      color: 0x8a9aaa, transparent: true, opacity: 0.13,
      side: THREE.DoubleSide, depthWrite: false,
    });
    [1, 2, 3.2].forEach(function(radius) {
      var ring = new THREE.Mesh(new THREE.RingGeometry(radius - 0.006, radius, 96), ringMaterial);
      ring.rotation.x = -Math.PI / 2;
      ring.position.y = FLOOR_Y + 0.009;
      g.add(ring);
    });
    scene.add(g);
  }
  buildRoom();

  function makeListenerMesh() {
    var g = new THREE.Group();
    // Abstract acoustic reference instrument. The acoustic origin stays at (0,0,0).
    // Opposed capsules express the left/right baseline; the inlay points to -Z.
    var profile = [[0,-0.28],[0.13,-0.27],[0.22,-0.20],[0.25,-0.08],
      [0.25,0.10],[0.21,0.22],[0.12,0.27],[0,0.28]];
    var shell = new THREE.Mesh(new THREE.LatheGeometry(
      new THREE.SplineCurve(profile.map(function(p){return new THREE.Vector2(p[0],p[1]);})).getPoints(48),64),mat.listener);
    shell.scale.z = 0.72;
    // Fine assembly seam and machined end caps identify an acoustic instrument.
    // These are local visual details; the acoustic origin and orientation stay fixed.
    var shellSeam = new THREE.Mesh(new THREE.TorusGeometry(0.2505, 0.0025, 6, 64), mat.chassis);
    shellSeam.rotation.x = Math.PI / 2;
    shellSeam.scale.y = 0.72;
    g.add(shellSeam);
    var capsuleGeo = new THREE.CylinderGeometry(0.095,0.095,0.018,48);
    [-1,1].forEach(function(side){
      var capsule=new THREE.Mesh(capsuleGeo,mat.listenerDark);
      capsule.rotation.z=Math.PI/2; capsule.position.x=side*0.249;
      var rim=new THREE.Mesh(new THREE.TorusGeometry(0.099,0.005,8,48),mat.driver);
      rim.rotation.y=Math.PI/2; rim.position.x=side*0.261;
      var inset = new THREE.Mesh(new THREE.CircleGeometry(0.077, 40), mat.rubber);
      inset.rotation.y = side * Math.PI / 2; inset.position.x = side * 0.260;
      var innerRim = new THREE.Mesh(new THREE.TorusGeometry(0.077, 0.002, 6, 40), mat.chassis);
      innerRim.rotation.y = Math.PI / 2; innerRim.position.x = side * 0.263;
      // One instanced draw for each capsule's acoustic grille.
      var grille = new THREE.InstancedMesh(new THREE.CircleGeometry(0.005, 8), mat.driver, 19);
      var pin = new THREE.Object3D();
      pin.rotation.y = side * Math.PI / 2;
      for (var gi = 0; gi < 19; gi++) {
        var gr = gi === 0 ? 0 : gi < 7 ? 0.025 : 0.05;
        var ga = gi < 7 ? (gi - 1) * Math.PI / 3 : (gi - 7) * Math.PI / 6;
        pin.position.set(side * 0.264, Math.cos(ga) * gr, Math.sin(ga) * gr);
        pin.updateMatrix(); grille.setMatrixAt(gi, pin.matrix);
      }
      g.add(capsule,rim,inset,innerRim,grille);
    });
    var stem = new THREE.Mesh(monitorEnclosure(0.09,0.77,0.10,0.025,0.008),mat.listenerDark);
    stem.position.y=-0.67;
    var baseProfile=[[0,FLOOR_Y+0.018],[0.34,FLOOR_Y+0.018],[0.36,FLOOR_Y+0.04],
      [0.34,FLOOR_Y+0.075],[0.19,FLOOR_Y+0.09],[0.07,FLOOR_Y+0.16]];
    var base=new THREE.Mesh(new THREE.LatheGeometry(baseProfile.map(function(p){return new THREE.Vector2(p[0],p[1]);}),64),mat.listenerDark);
    var rim=new THREE.Mesh(new THREE.TorusGeometry(0.343,0.005,8,80),mat.handle);
    rim.rotation.x=Math.PI/2;rim.position.y=FLOOR_Y+0.066;
    var inlay=new THREE.Mesh(monitorEnclosure(0.022,0.25,0.009,0.008,0.002),mat.handle);
    inlay.position.set(0,0,-0.181);
    var spine = new THREE.Mesh(monitorEnclosure(0.038, 0.53, 0.006, 0.009, 0.001), mat.chassis);
    spine.position.set(0, -0.68, 0.052);
    var rearInlay = new THREE.Mesh(monitorEnclosure(0.025, 0.10, 0.006, 0.009, 0.001), mat.chassis);
    rearInlay.position.set(0, 0.025, 0.181);
    g.add(spine, rearInlay);
    var fin = new THREE.Mesh(geo.forwardFin, mat.field);
    fin.rotation.x=-Math.PI/2;fin.position.set(0,FLOOR_Y+0.03,-0.50);
    var tag=makeLabelSprite('Listener',0.9,'rgba(223,233,244,0.85)');
    tag.position.set(0,FLOOR_Y+0.025,0.51);
    var shadow=new THREE.Mesh(geo.shadow,mat.shadow);
    shadow.rotation.x=-Math.PI/2;shadow.position.y=FLOOR_Y+0.011;shadow.scale.setScalar(2.6);
    g.add(shell,stem,base,rim,inlay,fin,tag,shadow);
    g.traverse(function(child){if(child.isMesh && child!==shadow)child.castShadow=true;});
    g.userData.kind = 'listener';
    g.userData.label = tag;
    return g;
  }

  function makeEmitterMesh(obj) {
    var g = new THREE.Group();
    var role = (obj && obj.visualRole) || '';
    var isSub = String(role).toUpperCase() === 'LFE';
    var body = new THREE.Mesh(isSub ? geo.subCabinet : geo.cabinet, mat.speaker);
    body.position.y = isSub ? 0 : 0.04;
    var baffle = new THREE.Mesh(isSub ? geo.subBaffle : geo.baffle, mat.baffle);
    baffle.position.set(0, isSub ? 0 : 0.04, isSub ? 0.265 : 0.194);
    var wooferTrim = new THREE.Mesh(geo.wooferTrim, mat.driver);
    wooferTrim.position.set(0, isSub ? -0.02 : -0.05, isSub ? 0.283 : 0.211);
    wooferTrim.scale.setScalar(isSub ? 1.75 : 1.40);
    var woofer = new THREE.Mesh(geo.woofer, mat.rubber);
    woofer.position.copy(wooferTrim.position);
    woofer.position.z += 0.014;
    woofer.scale.setScalar(isSub ? 1.75 : 1.40);
    var cone = new THREE.Mesh(geo.cone, mat.cone);
    cone.rotation.x = Math.PI / 2;
    cone.position.copy(woofer.position);
    cone.position.z += 0.014;
    cone.scale.setScalar(isSub ? 1.65 : 1.40);
    var dustCap = new THREE.Mesh(geo.dustCap, mat.cone);
    dustCap.position.copy(cone.position);
    dustCap.position.z -= 0.019;
    dustCap.scale.set(isSub ? 1.65 : 1.40, isSub ? 1.65 : 1.40, 0.45);
    var tweeterTrim = new THREE.Mesh(geo.tweeterTrim, mat.driver);
    tweeterTrim.rotation.x = Math.PI / 2;
    tweeterTrim.scale.set(1.55,1,1.22);
    tweeterTrim.position.set(0, 0.17, 0.23);
    var tweeter = new THREE.Mesh(geo.tweeter, mat.driver);
    tweeter.scale.z = 0.48;
    tweeter.position.set(0, 0.17, 0.223);
    var stand = new THREE.Mesh(geo.stand, mat.chassis);
    stand.position.y = -0.69;
    var base = new THREE.Mesh(geo.base, mat.chassis);
    base.position.y = FLOOR_Y + 0.03;
    var standPlate = new THREE.Mesh(geo.standPlate, mat.baffle);
    standPlate.position.y = -0.29;
    standPlate.visible = !isSub;
    stand.visible = !isSub;
    base.visible = !isSub;
    var shadow = new THREE.Mesh(geo.shadow, mat.shadow.clone());
    shadow.rotation.x = -Math.PI / 2;
    shadow.scale.setScalar(isSub ? 2.1 : 1.85);
    shadow.renderOrder = -1;
    g.add(body, baffle, wooferTrim, woofer, cone, dustCap, stand, standPlate, base, shadow);
    if (!isSub) g.add(tweeterTrim, tweeter);
    // A layered driver seat makes the baffle read as assembled hardware.
    // The recessed cone remains forward of the solid baffle, avoiding occlusion.
    var driverSeat = new THREE.Mesh(new THREE.TorusGeometry(0.113, 0.0035, 8, 48), mat.chassis);
    driverSeat.position.copy(wooferTrim.position);
    driverSeat.position.z += 0.004;
    driverSeat.scale.setScalar(isSub ? 1.75 : 1.40);
    g.add(driverSeat);
    var fasteners = new THREE.InstancedMesh(geo.driverFastener, mat.chassis, 6);
    var fastener = new THREE.Object3D();
    fastener.rotation.x = Math.PI / 2;
    for (var fi = 0; fi < 6; fi++) {
      var fa = (fi + 0.5) * Math.PI / 3;
      var fr = 0.108 * (isSub ? 1.75 : 1.40);
      fastener.position.set(Math.sin(fa) * fr, wooferTrim.position.y + Math.cos(fa) * fr, wooferTrim.position.z + 0.005);
      fastener.updateMatrix(); fasteners.setMatrixAt(fi, fastener.matrix);
    }
    g.add(fasteners);
    if (!isSub) {
      var collar = new THREE.Mesh(geo.standCollar, mat.chassis);
      collar.position.y = FLOOR_Y + 0.073;
      var baseInset = new THREE.Mesh(geo.base, mat.rubber);
      baseInset.scale.set(0.92, 0.24, 0.91);
      baseInset.position.y = FLOOR_Y + 0.010;
      g.add(collar, baseInset);
      [-1, 1].forEach(function (sx) {
        [-1, 1].forEach(function (sz) {
          var pad = new THREE.Mesh(geo.isolationPad, mat.rubber);
          pad.position.set(sx * 0.10, -0.266, sz * 0.08);
          g.add(pad);
        });
      });
    }
    // Small fasteners, rear amplifier plate and vent distinguish a real enclosure
    // even when the front baffle correctly faces away from the camera.
    var screwGeometry = new THREE.SphereGeometry(0.009, 8, 6);
    [-1, 1].forEach(function(x) {
      [-1, 1].forEach(function(y) {
        var screw = new THREE.Mesh(screwGeometry, mat.driver);
        screw.position.set(x * (isSub ? 0.225 : 0.165), y * 0.235 + (isSub ? 0 : 0.04), isSub ? 0.279 : 0.21);
        g.add(screw);
      });
    });
    var rearPlate = new THREE.Mesh(geo.rearPlate, mat.chassis);
    rearPlate.position.set(0, -0.015, isSub ? -0.26 : -0.191);
    g.add(rearPlate);
    var fins = new THREE.InstancedMesh(geo.rearFin, mat.baffle, 9);
    var finTransform = new THREE.Object3D();
    for (var ri = 0; ri < 9; ri++) {
      finTransform.position.set((ri - 4) * 0.019, 0.017, isSub ? -0.272 : -0.205);
      finTransform.updateMatrix(); fins.setMatrixAt(ri, finTransform.matrix);
    }
    g.add(fins);
    for (var vi=0; vi<5; vi++) {
      var vent = new THREE.Mesh(new THREE.BoxGeometry(0.16, 0.008, 0.007), mat.driver);
      vent.position.set(0, 0.06 - vi * 0.026, isSub ? -0.269 : -0.20);
      g.add(vent);
    }
    // Recessed bass port, a machined badge and rear connector well.
    var port=new THREE.Mesh(monitorEnclosure(0.22,0.025,0.012,0.01,0.002),mat.rubber);
    port.position.set(0,-0.207,isSub?0.282:0.212);g.add(port);
    var badge=new THREE.Mesh(monitorEnclosure(0.052,0.012,0.005,0.003,0.001),mat.handle);
    badge.position.set(0,-0.245,isSub?0.284:0.214);g.add(badge);
    [-0.056,0.056].forEach(function(x){
      var socket=new THREE.Mesh(new THREE.TorusGeometry(0.022,0.004,8,20),mat.driver);
      socket.position.set(x,-0.11,isSub?-0.27:-0.202);g.add(socket);
    });
    var led = new THREE.Mesh(new THREE.SphereGeometry(0.008, 8, 6), mat.field);
    led.position.set(0.12, -0.19, 0.214); g.add(led);
    g.traverse(function (child) {
      if (child.isMesh && child !== shadow) child.castShadow = true;
    });
    g.userData.kind = 'emitter';
    g.userData.body = body;
    g.userData.visualRole = obj && obj.visualRole;
    if (role) {
      var tag = makeLabelSprite(String(role), 0.52, 'rgba(188,205,222,0.64)');
      tag.position.y = isSub ? 0.43 : 0.49;
      tag.visible = false;
      g.add(tag);
      g.userData.label = tag;
    }
    g.userData.shadow = shadow;
    g.userData.isSub = isSub;
    return g;
  }

  function makeSourceMesh() {
    var g = new THREE.Group();
    var core = new THREE.Mesh(geo.sourceCore, mat.sourceCore);
    var shell = new THREE.Mesh(geo.sourceShell, mat.sourceShell);
    // Split satin shell around a restrained luminous equator: a Yinwei acoustic lens.
    core.scale.set(1.55,0.10,1.55);
    var shellMaterial=new THREE.MeshStandardMaterial({color:0x8c969e,metalness:0.7,roughness:0.28,envMapIntensity:0.95});
    shell.geometry=new THREE.SphereGeometry(0.235,48,24,0,Math.PI*2,0,Math.PI/2);
    shell.material=shellMaterial; shell.scale.y=0.72; shell.position.y=0.012;
    var lower=shell.clone();lower.rotation.z=Math.PI;lower.position.y=-0.012;
    lower.material = mat.chassis;
    var seam=new THREE.Mesh(new THREE.TorusGeometry(0.234,0.006,10,80),mat.sourceCore);
    seam.rotation.x=Math.PI/2;
    var cap=new THREE.Mesh(new THREE.CylinderGeometry(0.058,0.058,0.008,40),mat.listenerDark);
    cap.position.y=0.184;
    g.add(lower,seam,cap);
    // Two engraved arcs on the crown echo the acoustic lens without a new effect.
    var engravingGeometry = new THREE.TorusGeometry(0.105, 0.002, 6, 36, Math.PI * 0.72);
    [0, Math.PI].forEach(function (angle) {
      var engraving = new THREE.Mesh(engravingGeometry, mat.chassis);
      engraving.rotation.set(Math.PI / 2, 0, angle);
      engraving.position.y = 0.164;
      g.add(engraving);
    });
    var field = new THREE.Mesh(geo.sourceField, mat.field);
    field.rotation.x = Math.PI / 2;
    field.scale.setScalar(1.1);
    var hit = new THREE.Mesh(
      geo.sourceHit,
      new THREE.MeshBasicMaterial({ visible: false })
    );
    var stem = new THREE.Mesh(geo.handleStem, mat.handle);
    stem.position.y = 0.27;
    stem.scale.y = 0.55;
    var knob = new THREE.Mesh(geo.handleKnob, mat.handle);
    knob.position.y = 0.4;
    knob.scale.setScalar(0.75);
    stem.userData.elevationHandle = true;
    knob.userData.elevationHandle = true;
    var tag = makeLabelSprite('Source', 0.86, 'rgba(220,238,255,0.88)');
    tag.position.y = -0.43;
    tag.visible = false;
    g.add(core, shell, field, hit, stem, knob, tag);
    core.castShadow = true;
    shell.castShadow = true;
    g.userData.kind = 'source';
    g.userData.visual = core;
    g.userData.field = field;
    g.userData.label = tag;
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

  var selectionRing = new THREE.Mesh(geo.selection, mat.selection);
  selectionRing.visible = false;
  selectionRing.renderOrder = 3;
  scene.add(selectionRing);

  var relationLine = new THREE.Line(
    new THREE.BufferGeometry().setFromPoints([
      new THREE.Vector3(),
      new THREE.Vector3(),
    ]),
    mat.relation
  );
  scene.add(relationLine);

  var relationDots = [];
  for (var di = 0; di < 5; di++) {
    var dot = new THREE.Mesh(
      new THREE.SphereGeometry(0.018, 10, 8),
      new THREE.MeshBasicMaterial({
        color: 0xb6c7d3,
        transparent: true,
        opacity: 0.2 - di * 0.02,
        depthWrite: false,
      })
    );
    scene.add(dot);
    relationDots.push(dot);
  }

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

  var _lineA = new THREE.Vector3();
  var _lineB = new THREE.Vector3();
  var _ear = new THREE.Vector3();

  function setLinePositions(line, a, b) {
    var attr = line.geometry.getAttribute('position');
    if (!attr || attr.count !== 2) {
      line.geometry.dispose();
      line.geometry = new THREE.BufferGeometry().setFromPoints([a, b]);
      return;
    }
    var arr = attr.array;
    arr[0] = a.x;
    arr[1] = a.y;
    arr[2] = a.z;
    arr[3] = b.x;
    arr[4] = b.y;
    arr[5] = b.z;
    attr.needsUpdate = true;
    line.geometry.computeBoundingSphere();
  }

  function decorateSourceVisual(mesh) {
    if (!mesh) {
      contactShadow.visible = false;
      relationLine.visible = false;
      dropLine.visible = false;
      relationDots.forEach(function (dot) { dot.visible = false; });
      return;
    }
    contactShadow.visible = true;
    contactShadow.position.set(mesh.position.x, FLOOR_Y + 0.01, mesh.position.z);
    var lift = Math.max(0.02, mesh.position.y - FLOOR_Y);
    var s = 0.7 + Math.min(1.4, lift * 0.18);
    contactShadow.scale.set(s, s, s);
    mat.shadow.opacity = 0.36 / (1 + lift * 0.32);
    mat.sourceCore.emissiveIntensity = state.active ? 0.3 + state.envelopment * 0.12 : 0.1;

    if (listener) _ear.copy(listener.position);
    else _ear.set(0, 0, 0);
    relationLine.visible = true;
    setLinePositions(relationLine, _ear, mesh.position);
    relationDots.forEach(function (dot, index) {
      dot.visible = true;
      dot.position.lerpVectors(_ear, mesh.position, (index + 1) / 6);
    });

    dropLine.visible = true;
    _lineA.copy(mesh.position);
    _lineB.set(mesh.position.x, FLOOR_Y + 0.02, mesh.position.z);
    setLinePositions(dropLine, _lineA, _lineB);
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

  function syncObjectLabels(focusMesh) {
    Object.keys(objectsById).forEach(function (id) {
      var mesh = objectsById[id];
      if (!mesh.userData.label) return;
      mesh.userData.label.visible =
        mesh.userData.kind !== 'emitter' || mesh === focusMesh || id === selectedObjectId || id === hoveredObjectId;
    });
  }

  function showSelectionHud(mesh) {
    var el = document.getElementById('sel');
    if (!mesh) {
      el.style.display = 'none';
      selectionHalo.visible = false;
      selectionRing.visible = false;
      syncObjectLabels(null);
      return;
    }
    var kind = mesh.userData.kind;
    var title =
      kind === 'source'
        ? 'SOURCE'
        : kind === 'listener'
          ? 'LISTENER'
          : String(mesh.userData.visualRole || mesh.userData.id || 'EMITTER').toUpperCase();
    var note =
      kind === 'emitter'
        ? 'Studio monitor · visual reference'
        : kind === 'source'
          ? 'Point source'
          : 'Listening origin';
    el.style.display = 'block';
    el.innerHTML = '<div class="ch">' + title + '</div><div class="muted">' + note + '</div>';
    selectionHalo.visible = true;
    selectionHalo.position.set(mesh.position.x, FLOOR_Y + 0.014, mesh.position.z);
    var hs = kind === 'source' ? 1.15 : kind === 'listener' ? 1.35 : 0.85;
    selectionHalo.scale.setScalar(hs);
    mat.halo.opacity = 0.38;
    selectionRing.visible = true;
    selectionRing.position.copy(mesh.position);
    selectionRing.scale.setScalar(kind === 'source' ? 1.45 : kind === 'listener' ? 1.3 : 1.05);
    selectionRing.lookAt(camera.position);
    syncObjectLabels(mesh);
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
          mesh.userData.id === selectedObjectId || mesh.userData.id === hoveredObjectId;
      }
      if (mesh.userData.shadow) {
        mesh.userData.shadow.position.y = FLOOR_Y - mesh.position.y + 0.012;
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
    if (selectedObjectId && objectsById[selectedObjectId]) {
      showSelectionHud(objectsById[selectedObjectId]);
    } else if (!selectedObjectId) {
      showSelectionHud(null);
    }
    needsRender = true;
  }

  function applyPlaybackTelemetry(next) {
    if (!next) return;
    var envelopment = typeof next.envelopment === 'number' ? next.envelopment : state.envelopment;
    var playing = typeof next.playing === 'boolean' ? next.playing : state.playing;
    var active = typeof next.active === 'boolean' ? next.active : state.active;
    var orbiting = typeof next.orbiting === 'boolean' ? next.orbiting : state.orbiting;
    if (typeof next.playhead === 'number') state.playhead = next.playhead;
    var visualChanged =
      envelopment !== state.envelopment ||
      playing !== state.playing ||
      active !== state.active;
    state.envelopment = envelopment;
    state.playing = playing;
    state.active = active;
    state.orbiting = orbiting;
    if (!visualChanged) return;
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
      basedOnRevision: gestureBasedOnRevision != null ? gestureBasedOnRevision : authoritativeRevision,
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
      gestureBasedOnRevision = authoritativeRevision;
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
              id === selectedObjectId || id === hoveredObjectId;
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
    gestureBasedOnRevision = null;
    orbitingCam = false;
    panningCam = false;
  });

  renderer.domElement.addEventListener('pointerleave', function () {
    hoveredObjectId = null;
    syncObjectLabels(selectedObjectId ? objectsById[selectedObjectId] : null);
    needsRender = true;
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
    free: { radius: 6.05, phi: 1.12, theta: 0.08, target: new THREE.Vector3(0.02, -0.1, -0.22) },
    top: { radius: 7.2, phi: 0.12, theta: 0, target: new THREE.Vector3(0, -0.06, -0.12) },
    front: { radius: 5.9, phi: 1.36, theta: 0, target: new THREE.Vector3(0, -0.04, -0.4) },
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
      radius: THREE.MathUtils.clamp(size.length() * 0.92, 5.6, 16),
      phi: 1.12,
      theta: 0.08,
      target: center.clone().add(new THREE.Vector3(0, -0.1, -0.2)),
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
    if (typeof document !== 'undefined' && document.hidden) return;
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
          0.28 + 0.06 * Math.sin(now * 0.004) + state.envelopment * 0.1;
      }
      needsRender = true;
    } else if (waveGroup.visible) {
      waveGroup.visible = false;
      needsRender = true;
    }

    if (selectionRing.visible) selectionRing.lookAt(camera.position);

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
      gestureBasedOnRevision: gestureBasedOnRevision,
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
      dragSourceHold: function (mode, steps, pixels) {
        if (!source) return { ok: false, reason: 'no-source' };
        var p = clientXY(source);
        var shift = mode === 'y';
        var count = Math.max(1, steps || 8);
        var delta = pixels || 4;
        firePointer('pointerdown', p.x, p.y, { buttons: 1, shift: shift });
        for (var i = 1; i <= count; i++) {
          firePointer('pointermove', p.x + (shift ? 0 : delta * i), p.y + (shift ? -delta * i : 0), {
            buttons: 1,
            shift: shift,
          });
        }
        firePointer('pointerup', p.x + (shift ? 0 : delta * count), p.y + (shift ? -delta * count : 0), {
          buttons: 0,
          shift: shift,
        });
        return debugInspect();
      },
      nudgeSource: function (dx, dy, dz, commit) {
        if (!source) return { ok: false, reason: 'no-source' };
        source.position.x += dx || 0;
        source.position.y += dy || 0;
        source.position.z += dz || 0;
        decorateSourceVisual(source);
        formatPose();
        showSelectionHud(source);
        needsRender = true;
        if (!gestureBasedOnRevision) gestureBasedOnRevision = authoritativeRevision;
        postSourceIntent(commit ? 'sourcePoseCommit' : 'sourcePosePreview', !!commit);
        if (commit) gestureBasedOnRevision = null;
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
