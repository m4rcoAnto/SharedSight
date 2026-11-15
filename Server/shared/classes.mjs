// Class metadata shared by the hub (fusion / prediction) and the dashboard (3D models).
// Labels are the 80 COCO names published by the bundled YOLO model. Sizes are nominal, in metres:
// they are used only when a phone could not measure the object's size, and are always clamped.
//   g: group   h/w/d: nominal height / width / depth   dyn: can move by itself
//   acc: plausible acceleration (m/s^2) for the motion model   tall: can hide a standing person
const C = (g, h, w, d, extra = {}) => ({ g, h, w, d, dyn: false, acc: 0.05, tall: h >= 1.2, ...extra });
const dyn = acc => ({ dyn: true, acc });

export const CLASSES = {
  person: C('person', 1.7, 0.5, 0.35, dyn(1.2)),
  bicycle: C('vehicle', 1.05, 0.5, 1.7, dyn(1.5)), car: C('vehicle', 1.5, 1.8, 4.2, dyn(2.5)),
  motorcycle: C('vehicle', 1.15, 0.7, 2.0, dyn(2.5)), airplane: C('vehicle', 3.5, 9, 10, dyn(2)),
  bus: C('vehicle', 3.0, 2.5, 10, dyn(1.5)), train: C('vehicle', 3.5, 2.8, 14, dyn(1.2)),
  truck: C('vehicle', 2.8, 2.4, 6.5, dyn(1.8)), boat: C('vehicle', 1.4, 2.0, 5, dyn(1)),
  'traffic light': C('street', 3.0, 0.35, 0.35), 'fire hydrant': C('street', 0.7, 0.3, 0.3),
  'stop sign': C('street', 2.2, 0.6, 0.08), 'parking meter': C('street', 1.3, 0.25, 0.25),
  bench: C('furniture', 0.85, 1.5, 0.6),
  bird: C('animal', 0.22, 0.14, 0.26, dyn(3)), cat: C('animal', 0.3, 0.18, 0.48, dyn(1.6)),
  dog: C('animal', 0.55, 0.25, 0.8, dyn(1.6)), horse: C('animal', 1.65, 0.55, 2.3, dyn(2)),
  sheep: C('animal', 0.85, 0.45, 1.1, dyn(1.5)), cow: C('animal', 1.45, 0.65, 2.3, dyn(1.2)),
  elephant: C('animal', 3.0, 1.6, 4.5, dyn(1)), bear: C('animal', 1.2, 0.8, 1.9, dyn(2)),
  zebra: C('animal', 1.4, 0.5, 2.2, dyn(2)), giraffe: C('animal', 4.6, 0.7, 2.6, dyn(1.5)),
  backpack: C('prop', 0.45, 0.32, 0.2), umbrella: C('prop', 0.95, 0.9, 0.9), handbag: C('prop', 0.28, 0.34, 0.14),
  tie: C('prop', 0.4, 0.09, 0.02), suitcase: C('prop', 0.65, 0.45, 0.26), frisbee: C('prop', 0.03, 0.26, 0.26),
  skis: C('prop', 0.08, 0.2, 1.7), snowboard: C('prop', 0.08, 0.28, 1.5),
  'sports ball': C('prop', 0.22, 0.22, 0.22, dyn(4)), kite: C('prop', 0.8, 0.8, 0.05),
  'baseball bat': C('prop', 0.07, 0.07, 0.85), 'baseball glove': C('prop', 0.12, 0.26, 0.28),
  skateboard: C('prop', 0.12, 0.2, 0.8, dyn(2)), surfboard: C('prop', 0.1, 0.5, 1.9),
  'tennis racket': C('prop', 0.03, 0.27, 0.68),
  bottle: C('prop', 0.26, 0.08, 0.08), 'wine glass': C('prop', 0.19, 0.08, 0.08), cup: C('prop', 0.1, 0.08, 0.08),
  fork: C('prop', 0.02, 0.03, 0.19), knife: C('prop', 0.02, 0.03, 0.22), spoon: C('prop', 0.02, 0.04, 0.18),
  bowl: C('prop', 0.08, 0.17, 0.17),
  banana: C('food', 0.05, 0.05, 0.19), apple: C('food', 0.08, 0.08, 0.08), sandwich: C('food', 0.07, 0.13, 0.13),
  orange: C('food', 0.08, 0.08, 0.08), broccoli: C('food', 0.13, 0.12, 0.12), carrot: C('food', 0.04, 0.04, 0.18),
  'hot dog': C('food', 0.05, 0.06, 0.17), pizza: C('food', 0.03, 0.32, 0.32), donut: C('food', 0.04, 0.1, 0.1),
  cake: C('food', 0.11, 0.24, 0.24),
  chair: C('furniture', 0.9, 0.5, 0.5), couch: C('furniture', 0.82, 1.9, 0.9),
  'potted plant': C('furniture', 0.85, 0.42, 0.42), bed: C('furniture', 0.6, 1.6, 2.0),
  'dining table': C('furniture', 0.75, 1.4, 0.85), toilet: C('furniture', 0.75, 0.4, 0.65),
  tv: C('furniture', 0.62, 1.05, 0.08), laptop: C('prop', 0.22, 0.33, 0.24), mouse: C('prop', 0.04, 0.06, 0.1),
  remote: C('prop', 0.02, 0.05, 0.18), keyboard: C('prop', 0.03, 0.44, 0.14), 'cell phone': C('prop', 0.01, 0.07, 0.15),
  microwave: C('furniture', 0.3, 0.5, 0.36), oven: C('furniture', 0.88, 0.6, 0.6), toaster: C('prop', 0.19, 0.28, 0.17),
  sink: C('furniture', 0.88, 0.6, 0.5), refrigerator: C('furniture', 1.8, 0.7, 0.7),
  book: C('prop', 0.03, 0.15, 0.22), clock: C('prop', 0.3, 0.3, 0.05), vase: C('prop', 0.3, 0.15, 0.15),
  scissors: C('prop', 0.01, 0.08, 0.2), 'teddy bear': C('prop', 0.4, 0.3, 0.25), 'hair drier': C('prop', 0.22, 0.08, 0.2),
  toothbrush: C('prop', 0.02, 0.02, 0.19),
};

const FALLBACK = C('prop', 0.5, 0.5, 0.5);
export const classInfo = label => CLASSES[label] ?? FALLBACK;

// Labels a detector commonly swaps for the same physical thing. Two observations with different labels
// may be the same object only inside one of these sets; otherwise the label must match exactly.
const CONFUSABLE = [
  ['couch', 'chair', 'bench', 'bed'], ['dog', 'cat', 'sheep', 'bear', 'teddy bear'], ['horse', 'cow', 'zebra'],
  ['car', 'truck', 'bus'], ['bicycle', 'motorcycle'], ['dining table', 'bench'], ['tv', 'laptop', 'microwave'],
  ['cup', 'bowl', 'wine glass', 'vase', 'bottle'], ['backpack', 'handbag', 'suitcase'], ['oven', 'refrigerator', 'microwave'],
];
const family = new Map();
CONFUSABLE.forEach((set, i) => set.forEach(l => family.set(l, (family.get(l) ?? new Set()).add(i))));
export function compatible(a, b) {
  if (a === b) return true;
  const fa = family.get(a), fb = family.get(b);
  if (!fa || !fb) return false;
  for (const i of fa) if (fb.has(i)) return true;
  return false;
}

// Worth tracking: whatever can move by itself, and obstacles big enough to walk into (same list as the app,
// NominalSize.isRelevant). Bottles, cups, bags, phones, books… are not obstacles for a walking person.
const OBSTACLES = new Set(['chair', 'couch', 'bed', 'dining table', 'bench', 'potted plant', 'toilet', 'refrigerator', 'oven', 'sink', 'tv',
  'suitcase', 'fire hydrant', 'stop sign', 'parking meter', 'traffic light', 'umbrella']);
export const relevant = label => !!CLASSES[label]?.dyn || OBSTACLES.has(label);
