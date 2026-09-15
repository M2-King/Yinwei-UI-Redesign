use serde_json::{json, Value};
use spatial_scene_contract::{
    clamp_dsp_distance_m, project_audio_v1, shortest_azimuth_delta_deg, wrap_azimuth_deg,
    AcousticFeedV1, AudioProjectionConfigV1, EmitterSlotStatusV1, PointSourceStatusV1,
    SceneApplyStatusV1, SpatialSceneStore, DSP_DISTANCE_MAX_M, DSP_DISTANCE_MIN_M,
};
use std::collections::BTreeMap;

fn load_coord() -> Value {
    serde_json::from_str(include_str!(
        "../../../contracts/v1/fixtures/coordinate_fixtures_v1.json"
    ))
    .unwrap()
}

fn case_by_id<'a>(fixture: &'a Value, id: &str) -> &'a Value {
    fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == id)
        .unwrap()
}

fn object(
    id: &str,
    ty: &str,
    x: f64,
    y: f64,
    z: f64,
    enabled: bool,
    active: bool,
    orientation: Option<[f64; 4]>,
    visual_role: Option<&str>,
) -> Value {
    let mut o = json!({
        "id": id,
        "type": ty,
        "worldPosition": { "x": x, "y": y, "z": z },
        "enabled": enabled,
        "active": active
    });
    if let Some([w, xq, yq, zq]) = orientation {
        o["orientation"] = json!({ "w": w, "x": xq, "y": yq, "z": zq });
    }
    if let Some(role) = visual_role {
        o["visualRole"] = json!(role);
    }
    o
}

fn scene(revision: u64, listener: Value, sources: Vec<Value>, emitters: Vec<Value>) -> Value {
    json!({
        "schemaVersion": 1,
        "revision": revision,
        "listener": listener,
        "sources": sources,
        "emitters": emitters
    })
}

fn default_scene(revision: u64, source_z: f64) -> Value {
    scene(
        revision,
        object(
            "listener-0",
            "listener",
            0.0,
            0.0,
            0.0,
            true,
            true,
            Some([1.0, 0.0, 0.0, 0.0]),
            None,
        ),
        vec![object(
            "source-0",
            "source",
            0.0,
            0.0,
            source_z,
            true,
            true,
            None,
            None,
        )],
        vec![],
    )
}

fn cfg(source: &str, bindings: &[(&str, &str)]) -> AudioProjectionConfigV1 {
    let mut emitter_bindings = BTreeMap::new();
    for (id, feed) in bindings {
        emitter_bindings.insert((*id).to_string(), (*feed).to_string());
    }
    AudioProjectionConfigV1 {
        point_source_id: source.to_string(),
        emitter_bindings,
    }
}

fn near(got: f64, want: f64, eps: f64) {
    assert!((got - want).abs() <= eps, "got {got} want {want}");
}

#[test]
fn empty_store_accepts_revision_zero() {
    let mut store = SpatialSceneStore::new();
    assert!(!store.has_scene());
    assert_eq!(store.applied_revision(), 0);

    let first = store.apply(&default_scene(0, -1.8));
    assert_eq!(first.status, SceneApplyStatusV1::Applied);
    assert!(!first.discontinuity);
    assert!(store.has_scene());
    assert_eq!(store.applied_revision(), 0);
    assert_eq!(store.snapshot().unwrap()["revision"].as_u64(), Some(0));

    let again = store.apply(&default_scene(0, -9.0));
    assert_eq!(again.status, SceneApplyStatusV1::RejectedStale);
    assert_eq!(store.applied_revision(), 0);
    assert_eq!(
        store.snapshot().unwrap()["sources"][0]["worldPosition"]["z"].as_f64(),
        Some(-1.8)
    );

    let next = store.apply(&default_scene(1, -2.0));
    assert_eq!(next.status, SceneApplyStatusV1::Applied);
    assert!(!next.discontinuity);
    assert_eq!(store.applied_revision(), 1);
    assert_eq!(
        store.snapshot().unwrap()["sources"][0]["worldPosition"]["z"].as_f64(),
        Some(-2.0)
    );
}

#[test]
fn store_revision_and_forbidden_keys() {
    let mut store = SpatialSceneStore::new();
    assert!(!store.has_scene());
    assert_eq!(store.applied_revision(), 0);

    let first = store.apply(&default_scene(1, -1.8));
    assert_eq!(first.status, SceneApplyStatusV1::Applied);
    assert_eq!(store.applied_revision(), 1);

    let sequential = store.apply(&default_scene(2, -2.0));
    assert_eq!(sequential.status, SceneApplyStatusV1::Applied);
    assert!(!sequential.discontinuity);

    let equal = store.apply(&default_scene(2, -9.0));
    assert_eq!(equal.status, SceneApplyStatusV1::RejectedStale);
    assert_eq!(
        store.snapshot().unwrap()["sources"][0]["worldPosition"]["z"].as_f64(),
        Some(-2.0)
    );

    let older = store.apply(&default_scene(1, -1.0));
    assert_eq!(older.status, SceneApplyStatusV1::RejectedStale);

    let gap = store.apply(&default_scene(5, -3.0));
    assert_eq!(gap.status, SceneApplyStatusV1::AppliedWithDiscontinuity);
    assert!(gap.discontinuity);
    assert_eq!(store.applied_revision(), 5);

    let invalid = store.apply(&json!({"schemaVersion": 1, "revision": 6}));
    assert_eq!(invalid.status, SceneApplyStatusV1::RejectedInvalid);
    assert_eq!(store.applied_revision(), 5);

    let mut with_camera = default_scene(6, -1.0);
    with_camera["camera"] = json!({"distance": 5});
    let forbidden = store.apply(&with_camera);
    assert_eq!(forbidden.status, SceneApplyStatusV1::RejectedInvalid);
    assert_eq!(store.applied_revision(), 5);
    assert!(store.snapshot().unwrap().get("camera").is_none());
    assert_eq!(store.snapshot().unwrap()["listener"]["id"], "listener-0");
    assert_eq!(store.snapshot().unwrap()["sources"][0]["id"], "source-0");
}

#[test]
fn projection_point_source_and_fixtures() {
    let coord = load_coord();
    let trig = coord["trigTolerance"].as_f64().unwrap();

    let front = project_audio_v1(&default_scene(1, -1.0), &cfg("source-0", &[]));
    assert!(front.is_success());
    near(front.point_source.as_ref().unwrap().azimuth_deg, 0.0, trig);
    assert_eq!(
        front.point_source.as_ref().unwrap().quaternion_storage_order,
        ["w", "x", "y", "z"]
    );

    let translated = case_by_id(&coord, "translated_listener");
    let t_scene = scene(
        1,
        object(
            "listener-0",
            "listener",
            translated["listener"]["worldPosition"]["x"].as_f64().unwrap(),
            translated["listener"]["worldPosition"]["y"].as_f64().unwrap(),
            translated["listener"]["worldPosition"]["z"].as_f64().unwrap(),
            true,
            true,
            Some([
                translated["listener"]["orientation"]["w"].as_f64().unwrap(),
                translated["listener"]["orientation"]["x"].as_f64().unwrap(),
                translated["listener"]["orientation"]["y"].as_f64().unwrap(),
                translated["listener"]["orientation"]["z"].as_f64().unwrap(),
            ]),
            None,
        ),
        vec![object(
            "source-0",
            "source",
            translated["world"]["x"].as_f64().unwrap(),
            translated["world"]["y"].as_f64().unwrap(),
            translated["world"]["z"].as_f64().unwrap(),
            true,
            true,
            None,
            None,
        )],
        vec![],
    );
    let t = project_audio_v1(&t_scene, &cfg("source-0", &[]));
    near(
        t.point_source.as_ref().unwrap().azimuth_deg,
        translated["expect"]["azimuthDeg"].as_f64().unwrap(),
        trig,
    );

    let rotated = case_by_id(&coord, "rotated_listener");
    let r_scene = scene(
        1,
        object(
            "listener-0",
            "listener",
            0.0,
            0.0,
            0.0,
            true,
            true,
            Some([
                rotated["listener"]["orientation"]["w"].as_f64().unwrap(),
                rotated["listener"]["orientation"]["x"].as_f64().unwrap(),
                rotated["listener"]["orientation"]["y"].as_f64().unwrap(),
                rotated["listener"]["orientation"]["z"].as_f64().unwrap(),
            ]),
            None,
        ),
        vec![object(
            "source-0",
            "source",
            rotated["world"]["x"].as_f64().unwrap(),
            rotated["world"]["y"].as_f64().unwrap(),
            rotated["world"]["z"].as_f64().unwrap(),
            true,
            true,
            None,
            None,
        )],
        vec![],
    );
    let r = project_audio_v1(&r_scene, &cfg("source-0", &[]));
    near(r.point_source.as_ref().unwrap().azimuth_deg, 0.0, trig);
    near(
        r.point_source.as_ref().unwrap().geometric_distance_m,
        2.0,
        trig,
    );

    let right = project_audio_v1(
        &scene(
            1,
            object("listener-0", "listener", 0.0, 0.0, 0.0, true, true, Some([1.0, 0.0, 0.0, 0.0]), None),
            vec![object("source-0", "source", 1.0, 0.0, 0.0, true, true, None, None)],
            vec![],
        ),
        &cfg("source-0", &[]),
    );
    near(right.point_source.as_ref().unwrap().azimuth_deg, 90.0, trig);

    let left = project_audio_v1(
        &scene(
            1,
            object("listener-0", "listener", 0.0, 0.0, 0.0, true, true, Some([1.0, 0.0, 0.0, 0.0]), None),
            vec![object("source-0", "source", -1.0, 0.0, 0.0, true, true, None, None)],
            vec![],
        ),
        &cfg("source-0", &[]),
    );
    near(left.point_source.as_ref().unwrap().azimuth_deg, -90.0, trig);

    let behind = project_audio_v1(&default_scene(1, 1.0), &cfg("source-0", &[]));
    near(behind.point_source.as_ref().unwrap().azimuth_deg, 180.0, trig);

    let up = project_audio_v1(
        &scene(
            1,
            object("listener-0", "listener", 0.0, 0.0, 0.0, true, true, Some([1.0, 0.0, 0.0, 0.0]), None),
            vec![object("source-0", "source", 0.0, 1.0, 0.0, true, true, None, None)],
            vec![],
        ),
        &cfg("source-0", &[]),
    );
    near(up.point_source.as_ref().unwrap().elevation_deg, 90.0, trig);

    let unnorm = project_audio_v1(
        &scene(
            1,
            object("listener-0", "listener", 0.0, 0.0, 0.0, true, true, Some([2.0, 0.0, 0.0, 0.0]), None),
            vec![object("source-0", "source", 0.0, 0.0, -1.0, true, true, None, None)],
            vec![],
        ),
        &cfg("source-0", &[]),
    );
    near(unnorm.point_source.as_ref().unwrap().azimuth_deg, 0.0, trig);
}

#[test]
fn projection_distance_binding_and_emitters() {
    let zero = project_audio_v1(&default_scene(1, 0.0), &cfg("source-0", &[]));
    assert_eq!(zero.point_source.as_ref().unwrap().geometric_distance_m, 0.0);
    near(zero.point_source.as_ref().unwrap().hrtf_unit.z, -1.0, 1e-9);
    assert_eq!(zero.point_source.as_ref().unwrap().dsp_distance_m, DSP_DISTANCE_MIN_M);

    let near_min = project_audio_v1(&default_scene(1, -0.2), &cfg("source-0", &[]));
    near(near_min.point_source.as_ref().unwrap().geometric_distance_m, 0.2, 1e-9);
    assert_eq!(near_min.point_source.as_ref().unwrap().dsp_distance_m, DSP_DISTANCE_MIN_M);

    let mid = project_audio_v1(&default_scene(1, -4.0), &cfg("source-0", &[]));
    near(mid.point_source.as_ref().unwrap().dsp_distance_m, 4.0, 1e-9);

    let far = project_audio_v1(&default_scene(1, -25.0), &cfg("source-0", &[]));
    near(far.point_source.as_ref().unwrap().geometric_distance_m, 25.0, 1e-9);
    assert_eq!(far.point_source.as_ref().unwrap().dsp_distance_m, DSP_DISTANCE_MAX_M);
    assert_eq!(clamp_dsp_distance_m(25.0), 10.0);

    let two = scene(
        1,
        object("listener-0", "listener", 0.0, 0.0, 0.0, true, true, Some([1.0, 0.0, 0.0, 0.0]), None),
        vec![
            object("decoy", "source", 9.0, 0.0, 0.0, true, true, None, None),
            object("wanted", "source", 0.0, 0.0, -1.0, true, true, None, None),
        ],
        vec![],
    );
    let bound = project_audio_v1(&two, &cfg("wanted", &[]));
    assert_eq!(bound.point_source.as_ref().unwrap().source_id, "wanted");
    near(bound.point_source.as_ref().unwrap().azimuth_deg, 0.0, 1e-6);

    let missing = project_audio_v1(&two, &cfg("missing", &[]));
    assert_eq!(missing.point_source_status, PointSourceStatusV1::SourceMissing);
    assert!(missing.point_source.is_none());

    let disabled = project_audio_v1(
        &scene(
            1,
            object("listener-0", "listener", 0.0, 0.0, 0.0, true, true, Some([1.0, 0.0, 0.0, 0.0]), None),
            vec![object("source-0", "source", 0.0, 0.0, -1.0, false, true, None, None)],
            vec![],
        ),
        &cfg("source-0", &[]),
    );
    assert_eq!(disabled.point_source_status, PointSourceStatusV1::SourceDisabled);

    let inactive = project_audio_v1(
        &scene(
            1,
            object("listener-0", "listener", 0.0, 0.0, 0.0, true, true, Some([1.0, 0.0, 0.0, 0.0]), None),
            vec![object("source-0", "source", 0.0, 0.0, -1.0, true, false, None, None)],
            vec![],
        ),
        &cfg("source-0", &[]),
    );
    assert_eq!(inactive.point_source_status, PointSourceStatusV1::SourceInactive);

    let emitters = scene(
        1,
        object("listener-0", "listener", 0.0, 0.0, 0.0, true, true, Some([1.0, 0.0, 0.0, 0.0]), None),
        vec![object("source-0", "source", 0.0, 0.0, -1.0, true, true, None, None)],
        vec![
            object("emitter-C", "emitter", 0.0, 0.0, -2.0, true, true, None, Some("C")),
            object("emitter-LFE", "emitter", 0.0, -1.0, 0.0, true, true, None, Some("LFE")),
            object("emitter-A", "emitter", 1.0, 0.0, 0.0, true, true, None, Some("R")),
            object("emitter-B", "emitter", -1.0, 0.0, 0.0, true, true, None, Some("L")),
        ],
    );
    let unbound = project_audio_v1(&emitters, &cfg("source-0", &[]));
    assert!(unbound.emitter_slots.is_empty());

    let center = project_audio_v1(&emitters, &cfg("source-0", &[("emitter-C", "center")]));
    assert_eq!(center.emitter_slots[0].status, EmitterSlotStatusV1::FailedInvalidFeed);

    let lfe = project_audio_v1(&emitters, &cfg("source-0", &[("emitter-LFE", "lfe")]));
    assert_eq!(lfe.emitter_slots[0].status, EmitterSlotStatusV1::FailedInvalidFeed);

    let ordered = project_audio_v1(
        &emitters,
        &cfg("source-0", &[("emitter-B", "left"), ("emitter-A", "right")]),
    );
    assert_eq!(
        ordered
            .emitter_slots
            .iter()
            .map(|s| s.emitter_id.as_str())
            .collect::<Vec<_>>(),
        vec!["emitter-A", "emitter-B"]
    );
    assert_eq!(ordered.emitter_slots[0].feed, Some(AcousticFeedV1::Right));
    assert_eq!(ordered.emitter_slots[1].feed, Some(AcousticFeedV1::Left));

    let unsorted = scene(
        1,
        object(
            "listener-0",
            "listener",
            0.0,
            0.0,
            0.0,
            true,
            true,
            Some([1.0, 0.0, 0.0, 0.0]),
            None,
        ),
        vec![object(
            "source-0",
            "source",
            0.0,
            0.0,
            -1.0,
            true,
            true,
            None,
            None,
        )],
        vec![
            object("emitter-Z", "emitter", 1.0, 0.0, 0.0, true, true, None, None),
            object("emitter-A", "emitter", -1.0, 0.0, 0.0, true, true, None, None),
            object("emitter-M", "emitter", 0.0, 0.0, 0.0, true, true, None, None),
        ],
    );
    let sorted = project_audio_v1(
        &unsorted,
        &cfg(
            "source-0",
            &[
                ("emitter-Z", "right"),
                ("emitter-A", "left"),
                ("emitter-M", "mid"),
            ],
        ),
    );
    assert_eq!(
        sorted
            .emitter_slots
            .iter()
            .map(|s| s.emitter_id.as_str())
            .collect::<Vec<_>>(),
        vec!["emitter-A", "emitter-M", "emitter-Z"]
    );
    assert_eq!(sorted.emitter_slots[0].feed, Some(AcousticFeedV1::Left));
    assert_eq!(sorted.emitter_slots[1].feed, Some(AcousticFeedV1::Mid));
    assert_eq!(sorted.emitter_slots[2].feed, Some(AcousticFeedV1::Right));

    let missing_listener = project_audio_v1(
        &json!({
            "schemaVersion": 1,
            "revision": 1,
            "sources": [object("source-0", "source", 0.0, 0.0, -1.0, true, true, None, None)],
            "emitters": [object("emitter-A", "emitter", 0.0, 0.0, 0.0, true, true, None, None)]
        }),
        &cfg("source-0", &[("emitter-A", "left")]),
    );
    assert_eq!(
        missing_listener.point_source_status,
        PointSourceStatusV1::InvalidScene
    );
    assert!(missing_listener.emitter_slots.is_empty());
    assert_eq!(missing_listener.reason.as_deref(), Some("missing_listener"));

    let mut with_camera = default_scene(1, -1.0);
    with_camera["camera"] = json!({"distance": 5});
    with_camera["emitters"] = json!([object(
        "emitter-A",
        "emitter",
        0.0,
        0.0,
        0.0,
        true,
        true,
        None,
        None
    )]);
    let forbidden = project_audio_v1(&with_camera, &cfg("source-0", &[("emitter-A", "left")]));
    assert_eq!(
        forbidden.point_source_status,
        PointSourceStatusV1::InvalidScene
    );
    assert!(forbidden.emitter_slots.is_empty());
    assert_eq!(forbidden.reason.as_deref(), Some("forbidden_key"));

    let bad = project_audio_v1(
        &emitters,
        &cfg("source-0", &[("emitter-missing", "left"), ("emitter-C", "rear")]),
    );
    assert!(bad
        .emitter_slots
        .iter()
        .any(|s| s.status == EmitterSlotStatusV1::FailedUnknownEmitter));
    assert!(bad
        .emitter_slots
        .iter()
        .any(|s| s.status == EmitterSlotStatusV1::FailedInvalidFeed));

    assert_eq!(AcousticFeedV1::parse("center"), None);
    assert_eq!(AcousticFeedV1::parse("LEFT"), Some(AcousticFeedV1::Left));
}

#[test]
fn angular_wrap_and_half_turn_from_phase1a_fixtures() {
    let coord = load_coord();
    let tight = coord["tolerance"].as_f64().unwrap();
    for id in [
        "wrap_plus_180",
        "wrap_minus_180",
        "wrap_plus_190",
        "wrap_minus_190",
    ] {
        let c = case_by_id(&coord, id);
        near(
            wrap_azimuth_deg(c["inputDeg"].as_f64().unwrap()),
            c["expectDeg"].as_f64().unwrap(),
            tight,
        );
    }
    let pos = case_by_id(&coord, "shortest_arc_half_turn_positive");
    let neg = case_by_id(&coord, "shortest_arc_half_turn_negative");
    near(
        shortest_azimuth_delta_deg(
            pos["fromDeg"].as_f64().unwrap(),
            pos["toDeg"].as_f64().unwrap(),
        ),
        pos["expectDeltaDeg"].as_f64().unwrap(),
        tight,
    );
    near(
        shortest_azimuth_delta_deg(
            neg["fromDeg"].as_f64().unwrap(),
            neg["toDeg"].as_f64().unwrap(),
        ),
        neg["expectDeltaDeg"].as_f64().unwrap(),
        tight,
    );
}
