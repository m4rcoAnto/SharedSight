# Research basis (checked 14 Nov 2026)

Each module was designed after checking the current literature. What was adopted, and what was deliberately not.

## NeuralObjectDetector / ObstacleSegmentationEngine
- **Ultralytics YOLO26** — Jocher et al., *Unified Real-Time End-to-End Vision Models*, arXiv:2606.03748 (2026); Sapkota et al.,
  arXiv:2509.25164; Chakrabarty, arXiv:2601.12882. NMS-free dual-head, DFL removed, built for edge export.
  → Adopted: YOLO26n-seg exported to Core ML. Output verified from the exported model spec: `[1,300,38]`
  (`x1,y1,x2,y2,score,class,32 mask coefficients`) and `[1,32,160,160]` prototypes; column order verified in the Ultralytics head source.
  No NMS stage and constant-time decoding. `YOLODecoder` also supports the classic `[1,4+nc+nm,A]` layout (YOLOv8/11) with NMS.
- Masks: YOLACT-style linear combination of prototypes, evaluated only inside each box (`MaskDecoder`).
- Not adopted: RF-DETR / D-FINE / DEIM (Apache-licensed real-time DETRs) — better licence, harder Core ML conversion; left as the swap-in option.

## TemporalObjectTracker
- Survey: *Deep Learning-Based Multi-Object Tracking*, arXiv:2506.13457 (ByteTrack and derivatives are the base of current SOTA).
- **ByteTrack** arXiv:2110.06864 → two-stage association (high-score, then low-score boxes for unmatched tracks).
- **OC-SORT** arXiv:2203.14360 → observation-centric velocity re-estimation after an occlusion gap (simplified ORU).
- **BoT-SORT** arXiv:2206.14651, **Deep OC-SORT** arXiv:2302.11813 → camera-motion compensation applied to the Kalman state. Here the
  compensation comes from the gyroscope instead of image registration (cheaper, works in low texture; no translation parallax).
- NSA Kalman (StrongSORT) → confidence-scaled measurement noise.
- Not adopted: appearance Re-ID embeddings (cost; and for people it drifts toward identity recognition, which is out of scope),
  UCMCTrack arXiv:2312.08952 (needs ground-plane camera calibration), McByte++ arXiv:2608.15688 (mask propagation), TrackTrack (CVPR 2025).
- Added beyond the papers: explicit `identityAmbiguous` flag and a hard re-association window — class equality never proves identity.

## SpatialRelevanceEstimator / distance
- **Depth Anything 3**, arXiv:2511.10647: metric monocular depth exists but needs known focal length, is a ViT-L model and is not
  validated for safety use on a phone. → Not integrated. Metric distance comes only from ARKit geometry (floor-plane raycast through
  the object's ground-contact point). Without it the app speaks camera-relative directions only.
- Unknown-obstacle sensing (floor segmentation, depth discontinuities, free space): evaluated, **not implemented**; the feature is
  capability-gated and reports `UNKNOWN_REGION`.

## SharedSightCollaborationEngine
- Liu et al., *Survey on Collaborative Perception*, arXiv:2308.16714: fusion quality depends on relative localisation; late fusion degrades
  sharply with pose error. CoRA, arXiv:2512.13191 (AAAI 2026): with late fusion a pose error mislocalises a collaborator's detection but
  does not corrupt it. *When Autonomous Vehicle Meets V2X*, arXiv:2509.24927: latency and pose error are the main online failure causes.
  → Adopted: late (object-level) fusion of metadata only; peer observations keep their source and are never merged into local detections;
  every observation is gated on a validated common frame, sender-reported position uncertainty, clock-synchronised age, and expiry.

## AudioFeedbackEngine / product framing
- Liu & Slade, *Mobilio*, Nature Biomedical Engineering 2026 (arXiv:2605.29120): survey of 112 BVI people — obstacle detection is one of three
  core needs; chest-worn phone; sensor fusion; personalised audio. → sparse, prioritised, de-duplicated announcements; verbosity setting;
  IMU fused with vision; audio mixed with (not replacing) environmental sound.
- arXiv:2504.20976 (monocular-depth guidance), NaviSense arXiv:2509.18672 (LiDAR + audio-haptic): support optional haptics and capability gating by sensor.

---

# Need, existing products and what Shared Sight adds (checked 14 Nov 2026)

Figures below come from search summaries of the cited sources, not from reading each source in full. Verify a number against
its source before it goes on a slide.

## Size of the need
| Fact | Number | Source |
|---|---|---|
| People with some vision impairment worldwide | at least 2.2 billion | WHO fact sheet |
| People who are blind (2020) | 43 million | IAPB Vision Atlas / Lancet Global Health |
| People with moderate to severe vision loss (2020) | 295 million | IAPB Vision Atlas |
| Blind people projected for 2050 | 61 million | Statista summary of the same study |
| Blind people in Italy (2020) | about 510,000 | IAPB Vision Atlas |

## Accidents while walking (Manduchi & Kurniawan, UC Santa Cruz, 2010, about 300 blind or legally blind respondents)
- 13% had a head-level accident at least once a month; 7% fell at least once a month.
- 23% of head injuries needed medical attention.
- A guide dog did not protect better than a long cane against these accidents.

## Platform
- WebAIM Screen Reader Survey #10 (2024): 91% of screen reader users use one on a phone; about 71% use VoiceOver.
  → iPhone first, and the app must be fully usable with VoiceOver.

## What already exists
- **Apple, built in and free:** VoiceOver Live Recognition (speaks scenes, people, doors, furniture, text from the camera);
  Detection Mode in Magnifier (distance to people, doors, furniture; needs LiDAR, so Pro iPhones); from May 2026, asking spoken
  questions about the camera view (needs Apple Intelligence).
- **Apps:** Microsoft Seeing AI, Google Lookout (Android), several LiDAR obstacle-distance apps.
- **Research:** Mobilio (already cited above): phone plus cane cut indoor obstacle contacts by about 41% with 14 participants.
- **Abandonment:** about 30% of assistive devices in general are abandoned within a year; reasons given are cost, lack of training
  and poor fit with real needs. No electronic aid has replaced the cane.

→ One phone that sees an obstacle and speaks is not a differentiator. Apple ships it.

## What none of the above does (found in this search)
1. Use what **another** camera sees. Each product knows only its own field of view.
2. Keep a short memory of an object that left the frame, labelled as not confirmed.
3. Say out loud when it **cannot** see.

These three are Shared Sight's reason to exist, and they drive the interface decisions below.

## Interface decisions that follow from the research
| Finding | Decision in the app |
|---|---|
| Users already rely on VoiceOver | Every control has a short label, a separate value and a hint; state toggles read as switches; alerts use the user's VoiceOver voice and speed when VoiceOver is on |
| Apple describes on request; a mobility aid must also warn | Both: automatic alerts, plus a "What is around me?" button that summarises on demand |
| One hand holds the cane | Magic Tap (two-finger double tap) pauses or resumes without finding a button; onboarding suggests wearing the phone on the chest |
| Abandonment follows poor fit and lack of training | Onboarding states limits in plain words; speaking speed and detail level are adjustable; a "Repeat last announcement" button |
| Low vision is far more common than blindness | Full Dynamic Type support (screen scrolls, buttons grow, columns stack), high contrast, Increase Contrast honoured, state always in words |
| Silent failure is the dangerous failure | Camera and link failures are announced through VoiceOver even when the app's own speech is off |
| Never imply safety | The on-demand summary of an empty scene ends with "This does not mean the way is clear" (unit-tested) |

---

# Shadow zones, fusion across phones, trajectory of hidden objects (checked 14 Nov 2026)

Abstracts and, where noted, the full text were read through search summaries; verify a claim against the paper before
quoting it.

## Tracking through occlusion (TemporalObjectTracker)
- **Occlusion-Aware SORT**, arXiv:2603.06034 (read in full): depth order from box bottom edges, an occlusion coefficient
  per track, an occlusion-aware offset in the association cost and a bias-aware momentum for weak detections. Authors
  note it only models short occlusions. → Adopted in simplified form: bottom-edge depth order, covered fraction as the
  occlusion coefficient (no Gaussian map: it costs about 15 ms per frame in the paper), cost offset, momentum for
  low-score matches, and a longer re-association window only while a nearer box explains the gap.
- **Occlusion-Aware MOT via Expected Probability of Detection**, arXiv:2511.20239: the probability of detection must
  depend on visibility; a miss while occluded should barely lower the belief that the object exists, a miss in plain
  view should lower it strongly. → Adopted as a rule rather than a filter: hidden = keep and predict; in clear view
  and undetected = evidence of absence (0.9 s grace, then dropped).

## Where is something nobody sees? (GroundTrackMemory, Server/world.mjs)
- **Schöller et al., What the Constant Velocity Model Can Teach Us About Pedestrian Motion Prediction**,
  arXiv:1903.07933 (RA-L 2020): constant velocity matches or beats neural predictors for pedestrians. → The predictor is
  constant velocity, damped (τ = 3 s) because a person who walks behind something often slows or stops, bounded by walls.
- **Khurana et al., Detecting Invisible People**, ICCV 2021: occluded people are handled by forecasting, and a track
  that lies in observed free space is not occluded. → Same split: estimate only where no camera can see.
- **Galceran, Olson, Eustice, Augmented Vehicle Tracking under Occlusions**, ICRA 2015: the estimate of an occluded
  object lives in the occluded part of the workspace. **Wyffels & Campbell, Negative Information for Occlusion
  Reasoning**, IEEE T-RO 2015. → An estimate that drifts into a camera's clear view is moved to the nearest hidden
  place it could have walked to, or dropped.
- **Don't double it: Efficient Agent Prediction in Occlusions**, arXiv:2601.21504 and **Out-of-Sight Trajectories**,
  arXiv:2509.15219: learned occupancy / trajectory prediction for hidden agents. → Not adopted: they need training data
  and a road-scene prior; noted as the upgrade path if recordings from the app become available.

## Many phones, one space (Server/world.mjs)
- **A Unified 3D Object Perception Framework for Real-Time Outside-In Multi-Camera Systems**, arXiv:2601.10819, and
  **EarlyBird**, arXiv:2310.13350: early (feature-level) fusion in bird's-eye view gives the best multi-camera tracking
  but needs calibrated, synchronised video on one machine. → Not possible with phones that share only metadata.
- **Fully distributed multi-view 3D tracking**, arXiv:2606.13127: each camera tracks in 3D on the ground plane and
  fuses with Kalman filtering; a target hidden from one node stays alive through the others. → Same idea, centralised
  on the hub: an object hidden from one phone stays OBSERVED while another measures it, and the hidden phone is told.
- **UniKF, uncertainty-aware late fusion of BEV detections**, arXiv:2507.03381 (read in full): constant-velocity Kalman
  filter, measurement covariance from each source, explicit handling of asynchronous sources. → Adopted: per-phone
  measurement variance (sender sigma + alignment error), measurements applied at arrival time. Not adopted: rollback
  for out-of-sequence data (phones send 10 times a second; a late frame is simply applied late).
- **Collaborative Trajectory Prediction via Late Fusion**, arXiv:2604.22973 and **Towards Collaborative Joint
  Perception and Prediction**, arXiv:2608.09541: object- and track-level fusion recovers occluded objects at a small
  communication cost; fusing predictions costs far more bandwidth for little gain. → Tracks are fused, predictions are
  made after fusion, never exchanged.
