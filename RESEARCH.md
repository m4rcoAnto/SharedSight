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
