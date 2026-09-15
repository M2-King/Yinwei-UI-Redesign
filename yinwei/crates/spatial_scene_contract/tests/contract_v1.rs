use serde_json::Value;
use spatial_scene_contract::{
    decide_revision_v1, geometric_distance_m, hrtf_unit_from_local, lerp_azimuth_deg,
    local_to_spherical, shortest_azimuth_delta_deg, spherical_to_local, validate_scene_v1,
    world_to_listener_local, wrap_azimuth_deg, ListenerPoseV1, QuatV1, RevisionDecisionV1,
    SpeakerSemanticsV1, SphericalV1, Vec3V1,
};

fn load_fixture(name: &str) -> Value {
    let raw = match name {
        "coordinate_fixtures_v1.json" => {
            include_str!("../../../contracts/v1/fixtures/coordinate_fixtures_v1.json")
        }
        "scene_fixtures_v1.json" => {
            include_str!("../../../contracts/v1/fixtures/scene_fixtures_v1.json")
        }
        "speaker_semantics_v1.json" => {
            include_str!("../../../contracts/v1/fixtures/speaker_semantics_v1.json")
        }
        other => panic!("unknown fixture {other}"),
    };
    serde_json::from_str(raw).expect("fixture json")
}

fn num(v: &Value) -> f64 {
    v.as_f64().expect("number")
}

fn vec3(v: &Value) -> Vec3V1 {
    Vec3V1::new(num(&v["x"]), num(&v["y"]), num(&v["z"]))
}

fn quat(v: &Value) -> QuatV1 {
    QuatV1::new(num(&v["w"]), num(&v["x"]), num(&v["y"]), num(&v["z"]))
}

fn near(got: f64, want: f64, eps: f64) {
    assert!(
        (got - want).abs() <= eps,
        "got {got} want {want} eps {eps}"
    );
}

fn near_vec(got: Vec3V1, want: &Value, eps: f64) {
    near(got.x, num(&want["x"]), eps);
    near(got.y, num(&want["y"]), eps);
    near(got.z, num(&want["z"]), eps);
}

#[test]
fn coordinate_frame_v1_fixtures() {
    let fixture = load_fixture("coordinate_fixtures_v1.json");
    assert_eq!(fixture["schemaId"], "CoordinateFrameV1");
    assert_eq!(
        fixture["quaternionStorageOrder"],
        serde_json::json!(["w", "x", "y", "z"])
    );
    let tight = num(&fixture["tolerance"]);
    let trig = num(&fixture["trigTolerance"]);
    for case in fixture["cases"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let kind = case["kind"].as_str().unwrap();
        let eps = if id.contains("elevation_near") {
            trig
        } else {
            tight
        };
        match kind {
            "pose_roundtrip" => {
                let input = &case["input"];
                let expect = &case["expect"];
                let pose = SphericalV1 {
                    azimuth_deg: num(&input["azimuthDeg"]),
                    elevation_deg: num(&input["elevationDeg"]),
                    distance_m: num(&input["distanceM"]),
                };
                let local = spherical_to_local(pose);
                near_vec(local, &expect["world"], eps);
                near_vec(local, &expect["listenerLocal"], eps);
                near_vec(hrtf_unit_from_local(local), &expect["hrtfUnit"], eps);
                let back = local_to_spherical(local);
                near(back.azimuth_deg, num(&expect["azimuthDeg"]), trig);
                near(back.elevation_deg, num(&expect["elevationDeg"]), trig);
                near(back.distance_m, num(&expect["distanceM"]), eps);
                near(
                    geometric_distance_m(local),
                    num(&expect["dspDistanceM"]),
                    eps,
                );
                near(hrtf_unit_from_local(local).length(), 1.0, tight);
            }
            "world_to_listener" => {
                let listener = ListenerPoseV1 {
                    world_position: vec3(&case["listener"]["worldPosition"]),
                    orientation: quat(&case["listener"]["orientation"]),
                };
                let world = vec3(&case["world"]);
                let local = world_to_listener_local(world, listener);
                let expect = &case["expect"];
                near_vec(local, &expect["listenerLocal"], trig);
                near_vec(hrtf_unit_from_local(local), &expect["hrtfUnit"], trig);
                let sph = local_to_spherical(local);
                near(sph.azimuth_deg, num(&expect["azimuthDeg"]), trig);
                near(sph.elevation_deg, num(&expect["elevationDeg"]), trig);
                near(sph.distance_m, num(&expect["distanceM"]), trig);
                near(
                    geometric_distance_m(local),
                    num(&expect["dspDistanceM"]),
                    trig,
                );
            }
            "wrap_azimuth" => {
                near(
                    wrap_azimuth_deg(num(&case["inputDeg"])),
                    num(&case["expectDeg"]),
                    tight,
                );
            }
            "shortest_arc" => {
                near(
                    shortest_azimuth_delta_deg(num(&case["fromDeg"]), num(&case["toDeg"])),
                    num(&case["expectDeltaDeg"]),
                    tight,
                );
                near(
                    lerp_azimuth_deg(
                        num(&case["fromDeg"]),
                        num(&case["toDeg"]),
                        num(&case["t"]),
                    ),
                    num(&case["expectInterpDeg"]),
                    tight,
                );
            }
            "cartesian_to_spherical" => {
                let local = vec3(&case["listenerLocal"]);
                let expect = &case["expect"];
                let sph = local_to_spherical(local);
                near(sph.azimuth_deg, num(&expect["azimuthDeg"]), trig);
                near(sph.elevation_deg, num(&expect["elevationDeg"]), trig);
                near(sph.distance_m, num(&expect["distanceM"]), tight);
                near_vec(hrtf_unit_from_local(local), &expect["hrtfUnit"], tight);
            }
            "zero_distance" => {
                let listener = ListenerPoseV1 {
                    world_position: vec3(&case["listener"]["worldPosition"]),
                    orientation: quat(&case["listener"]["orientation"]),
                };
                let world = vec3(&case["world"]);
                let local = world_to_listener_local(world, listener);
                let expect = &case["expect"];
                near_vec(local, &expect["listenerLocal"], tight);
                near_vec(hrtf_unit_from_local(local), &expect["hrtfUnit"], tight);
                let sph = local_to_spherical(local);
                near(sph.azimuth_deg, num(&expect["azimuthDeg"]), tight);
                near(sph.elevation_deg, num(&expect["elevationDeg"]), tight);
                near(sph.distance_m, num(&expect["distanceM"]), tight);
                assert!(expect["dspDistanceIndependent"].as_bool().unwrap());
                near(hrtf_unit_from_local(local).length(), 1.0, tight);
                near(geometric_distance_m(local), 0.0, tight);
            }
            other => panic!("unknown kind {other} in {id}"),
        }
    }
}

#[test]
fn scene_contract_v1_fixtures() {
    let fixture = load_fixture("scene_fixtures_v1.json");
    assert_eq!(fixture["schemaId"], "SceneContractV1");
    for case in fixture["cases"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        match case["kind"].as_str().unwrap() {
            "validate" => {
                let result = validate_scene_v1(&case["scene"]);
                let expect = &case["expect"];
                assert_eq!(result.valid, expect["valid"].as_bool().unwrap(), "{id}");
                if !result.valid {
                    assert_eq!(
                        result.reason.as_deref(),
                        expect["reason"].as_str(),
                        "{id}"
                    );
                }
            }
            "revision" => {
                let verdict = decide_revision_v1(
                    case["appliedRevision"].as_u64().unwrap(),
                    case["incomingRevision"].as_u64().unwrap(),
                );
                let expect = &case["expect"];
                assert_eq!(verdict.apply(), expect["apply"].as_bool().unwrap(), "{id}");
                if !verdict.apply() {
                    assert_eq!(verdict.decision, RevisionDecisionV1::RejectStale, "{id}");
                }
                if expect.get("discontinuity").and_then(|v| v.as_bool()) == Some(true) {
                    assert!(verdict.discontinuity, "{id}");
                }
            }
            other => panic!("unknown kind {other}"),
        }
    }
}

#[test]
fn speaker_semantics_v1_fixtures() {
    let fixture = load_fixture("speaker_semantics_v1.json");
    assert_eq!(fixture["schemaId"], "SpeakerSemanticsV1");
    let engine = &fixture["currentEngine"];
    assert_eq!(SpeakerSemanticsV1::INPUT, engine["input"]);
    assert_eq!(
        SpeakerSemanticsV1::INPUT_CHANNEL_COUNT,
        engine["inputChannelCount"].as_u64().unwrap() as u32
    );
    let feeds: Vec<&str> = engine["acousticFeeds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(SpeakerSemanticsV1::ACOUSTIC_FEEDS, feeds.as_slice());
    assert!(!SpeakerSemanticsV1::IS_DISCRETE_71);
    assert!(!SpeakerSemanticsV1::TRUE_MULTICHANNEL_ROUTING_IN_SCOPE);
    assert_eq!(SpeakerSemanticsV1::MAX_VISUAL_EMITTERS, 8);
    for name in fixture["cases"][4]["expect"]["unknownFeeds"]
        .as_array()
        .unwrap()
    {
        assert!(!SpeakerSemanticsV1::is_acoustic_feed(name.as_str().unwrap()));
    }
}
