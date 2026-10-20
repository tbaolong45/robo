// Expression table: (activity, emotion) -> target FaceParams. Port of src/robo/face/expressions.py.
//
// Units: eyeW/eyeH/mouthW are scale factors (1 = default), gaze in -1..1, lids 0..1,
// lidAngle > 0 lowers the inner lid edge (focused/cross), < 0 raises it (sad/worried),
// skew > 0 makes the right eye bigger, hue in degrees.

/// One animatable number of a face; the animator springs each of these.
public typealias FaceKey = WritableKeyPath<FaceParams, Double>

public struct FaceParams: Equatable, Sendable {
    public var eyeW = 1.0
    public var eyeH = 1.0
    public var eyeRound = 0.55
    public var gazeX = 0.0
    public var gazeY = 0.0
    public var lidTop = 0.0
    public var lidAngle = 0.0
    public var lidBottom = 0.0
    public var skew = 0.0
    public var wink = 0.0  // 1 closes the left eye
    public var mouthCurve = 0.15
    public var mouthOpen = 0.0
    public var mouthW = 1.0
    public var hue = 188.0
    public var sat = 0.85
    public var glow = 0.8
    public var wander = 0.0  // how much the animator lets the gaze drift
    public var bob = 0.0  // breathing offset, set by the animator
    public var effects = Set<String>()

    public init() {}

    /// Every number the animator eases (all but `bob`, which it sets, and `effects`).
    public static let floats: [FaceKey] = [
        \.eyeW, \.eyeH, \.eyeRound, \.gazeX, \.gazeY, \.lidTop, \.lidAngle, \.lidBottom, \.skew, \.wink,
        \.mouthCurve, \.mouthOpen, \.mouthW, \.hue, \.sat, \.glow, \.wander,
    ]

    private struct Spec {
        var values: [FaceKey: Double]
        var fx: Set<String> = []
    }

    // Activity sets the base pose (absolute values). `fx` lists overlay effects.
    private static let activitySpecs: [Activity: Spec] = [
        .idle: Spec(values: [\.wander: 1.0]),
        .listening: Spec(values: [\.eyeW: 1.05, \.eyeH: 1.12, \.gazeY: -0.1, \.wander: 0.4, \.mouthW: 0.8],
                         fx: ["pulse"]),
        .thinking: Spec(values: [\.eyeW: 0.85, \.eyeH: 0.85, \.gazeX: 0.6, \.gazeY: -0.7, \.skew: 0.15,
                                 \.mouthW: 0.6, \.mouthCurve: -0.1], fx: ["dots"]),
        .working: Spec(values: [\.eyeW: 1.08, \.eyeH: 0.9, \.lidTop: 0.3, \.lidAngle: 0.08, \.gazeY: 0.35,
                                \.mouthW: 0.6, \.mouthCurve: 0.0], fx: ["gear"]),
        .talking: Spec(values: [\.eyeH: 1.05, \.mouthW: 1.1, \.wander: 0.3]),
        .waiting: Spec(values: [\.eyeH: 1.18, \.gazeY: -0.2, \.lidAngle: -0.12, \.mouthW: 0.75,
                                \.mouthCurve: 0.25]),
        .error: Spec(values: [\.eyeW: 0.9, \.eyeH: 0.75, \.lidTop: 0.15, \.lidAngle: -0.35, \.mouthCurve: -0.45,
                              \.mouthW: 0.8, \.hue: 356.0, \.sat: 0.75], fx: ["sweat"]),
        .sleepy: Spec(values: [\.lidTop: 0.55, \.gazeY: 0.3, \.glow: 0.5, \.sat: 0.65, \.mouthW: 0.6,
                               \.mouthCurve: 0.05]),
        .asleep: Spec(values: [\.eyeH: 0.1, \.eyeRound: 1.0, \.gazeY: 0.45, \.glow: 0.35, \.sat: 0.55,
                               \.mouthW: 0.45, \.mouthCurve: 0.0], fx: ["zzz"]),
    ]

    // Emotion overlays: deltas added to the base, except hue/sat which replace it
    // (unless the activity owns the colour, e.g. error).
    private static let emotionSpecs: [String: Spec] = [
        "neutral": Spec(values: [:]),
        "happy": Spec(values: [\.lidBottom: 0.55, \.eyeH: 0.05, \.mouthCurve: 0.85, \.mouthW: 0.15, \.hue: 168.0],
                      fx: ["blush"]),
        "curious": Spec(values: [\.skew: 0.4, \.gazeX: 0.35, \.gazeY: -0.15, \.eyeH: 0.12, \.mouthW: -0.5,
                                 \.mouthOpen: 0.2, \.mouthCurve: -0.05]),
        "proud": Spec(values: [\.lidTop: 0.18, \.lidBottom: 0.42, \.gazeY: -0.35, \.mouthCurve: 0.75,
                               \.mouthW: 0.2, \.hue: 44.0, \.sat: 0.7], fx: ["sparkle"]),
        "concerned": Spec(values: [\.lidTop: 0.12, \.lidAngle: -0.55, \.gazeY: 0.1, \.mouthCurve: -0.4,
                                   \.mouthW: -0.25, \.hue: 34.0, \.sat: 0.8], fx: ["sweat"]),
        "confused": Spec(values: [\.skew: -0.5, \.lidAngle: 0.25, \.gazeX: -0.35, \.gazeY: -0.1,
                                  \.mouthCurve: -0.3, \.mouthW: -0.3], fx: ["question"]),
        "playful": Spec(values: [\.lidBottom: 0.45, \.wink: 1.0, \.gazeX: -0.3, \.mouthCurve: 0.75,
                                 \.mouthOpen: 0.35, \.hue: 318.0, \.sat: 0.45], fx: ["blush"]),
        "sad": Spec(values: [\.lidTop: 0.22, \.lidAngle: -0.6, \.gazeY: 0.4, \.eyeH: -0.08, \.mouthCurve: -0.85,
                             \.mouthW: -0.2, \.glow: -0.2, \.hue: 216.0, \.sat: 0.8]),
        "calm": Spec(values: [\.lidTop: 0.4, \.mouthCurve: 0.35, \.mouthW: -0.25, \.glow: -0.2,
                              \.wander: -0.6, \.hue: 176.0, \.sat: 0.6]),
    ]

    private static let limits: [(FaceKey, ClosedRange<Double>)] = [
        (\.eyeW, 0.3...1.6), (\.eyeH, 0.05...1.6), (\.lidTop, 0...1), (\.lidBottom, 0...1),
        (\.lidAngle, -1...1), (\.skew, -1...1), (\.gazeX, -1...1), (\.gazeY, -1...1),
        (\.mouthCurve, -1...1), (\.mouthOpen, 0...1), (\.mouthW, 0.2...1.6), (\.sat, 0...1),
        (\.glow, 0...1), (\.wander, 0...1), (\.wink, 0...1),
    ]
    private static let maxLids = 0.7  // top + bottom lid coverage, so eyes never vanish

    /// The resting face for this activity with the emotion layered on top (an unknown emotion adds nothing).
    public static func target(_ activity: Activity, _ emotion: String) -> FaceParams {
        let act = activitySpecs[activity]!
        let emo = activity == .asleep ? nil : emotionSpecs[emotion]
        var p = FaceParams()
        for (k, v) in act.values { p[keyPath: k] = v }
        for (k, v) in emo?.values ?? [:] {
            if k == \FaceParams.hue || k == \FaceParams.sat {
                if act.values[k] == nil { p[keyPath: k] = v }
            } else {
                p[keyPath: k] += v
            }
        }
        for (k, r) in limits { p[keyPath: k] = min(r.upperBound, max(r.lowerBound, p[keyPath: k])) }
        let lids = p.lidTop + p.lidBottom
        if lids > maxLids {
            p.lidTop *= maxLids / lids
            p.lidBottom *= maxLids / lids
        }
        p.effects = act.fx.union(emo?.fx ?? [])
        return p
    }
}
