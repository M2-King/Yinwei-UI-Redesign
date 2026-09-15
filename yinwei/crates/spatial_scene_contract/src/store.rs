//! SpatialSceneStore — authoritative SceneContractV1 holder.

use serde_json::Value;

use crate::scene::{decide_revision_v1, validate_scene_v1, RevisionDecisionV1};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SceneApplyStatusV1 {
    Applied,
    AppliedWithDiscontinuity,
    RejectedStale,
    RejectedInvalid,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneApplyResultV1 {
    pub status: SceneApplyStatusV1,
    pub reason: Option<String>,
    pub discontinuity: bool,
}

impl SceneApplyResultV1 {
    pub fn accepted(&self) -> bool {
        matches!(
            self.status,
            SceneApplyStatusV1::Applied | SceneApplyStatusV1::AppliedWithDiscontinuity
        )
    }
}

#[derive(Clone, Debug, Default)]
pub struct SpatialSceneStore {
    applied_revision: u64,
    scene: Option<Value>,
}

impl SpatialSceneStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn applied_revision(&self) -> u64 {
        self.applied_revision
    }

    pub fn has_scene(&self) -> bool {
        self.scene.is_some()
    }

    /// Deep clone of the accepted snapshot.
    pub fn snapshot(&self) -> Option<Value> {
        self.scene.clone()
    }

    pub fn apply(&mut self, incoming: &Value) -> SceneApplyResultV1 {
        let validation = validate_scene_v1(incoming);
        if !validation.valid {
            return SceneApplyResultV1 {
                status: SceneApplyStatusV1::RejectedInvalid,
                reason: validation.reason,
                discontinuity: false,
            };
        }
        let incoming_revision = incoming
            .get("revision")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let verdict = decide_revision_v1(self.applied_revision, incoming_revision);
        if verdict.decision == RevisionDecisionV1::RejectStale {
            return SceneApplyResultV1 {
                status: SceneApplyStatusV1::RejectedStale,
                reason: Some("stale_revision".into()),
                discontinuity: false,
            };
        }
        self.scene = Some(incoming.clone());
        self.applied_revision = incoming_revision;
        if verdict.discontinuity {
            SceneApplyResultV1 {
                status: SceneApplyStatusV1::AppliedWithDiscontinuity,
                reason: None,
                discontinuity: true,
            }
        } else {
            SceneApplyResultV1 {
                status: SceneApplyStatusV1::Applied,
                reason: None,
                discontinuity: false,
            }
        }
    }
}
