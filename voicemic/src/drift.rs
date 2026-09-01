//! Clock-drift compensation between two independent audio devices.
//!
//! The microphone and the virtual output device run on separate clocks. Even a
//! 0.01% mismatch accumulates to a full buffer of drift within minutes, which is
//! why a naive bridge glitches after ten minutes rather than ten seconds. The fix
//! is to treat the output ring's fill level as the process variable and trim the
//! resampler ratio to hold it constant.
//!
//! Fill level is the integral of the rate error, so proportional control alone
//! leaves a steady-state offset. A small integral term removes it. Output is
//! clamped to +/-0.5% (about 8.6 cents) and slew-limited, both well below audibility
//! for speech.

/// Largest fractional deviation from unity ratio. 0.5% is inaudible on speech and
/// far exceeds any real crystal mismatch (typically < 100 ppm).
pub const MAX_DEVIATION: f64 = 0.005;

/// Largest ratio change per update, to keep correction free of audible modulation.
const MAX_SLEW_PER_UPDATE: f64 = 2.0e-5;

/// Proportional gain, expressed per unit of normalised fill error.
const KP: f64 = 2.0e-3;

/// Integral gain, per unit of normalised fill error per update.
const KI: f64 = 4.0e-6;

/// Holds a ring buffer's fill level at a target by trimming a resampler ratio.
#[derive(Debug, Clone)]
pub struct DriftController {
    target_fill: f64,
    integral: f64,
    ratio: f64,
}

impl DriftController {
    /// `target_fill_samples` is the steady-state occupancy to hold, in samples.
    /// It should be at least the worst-case jitter the worker thread can impose.
    pub fn new(target_fill_samples: usize) -> Self {
        Self {
            target_fill: target_fill_samples.max(1) as f64,
            integral: 0.0,
            ratio: 1.0,
        }
    }

    /// Current ratio: output samples produced per input sample.
    pub fn ratio(&self) -> f64 {
        self.ratio
    }

    pub fn target_fill(&self) -> f64 {
        self.target_fill
    }

    /// Feed the observed ring fill and get the ratio to apply next.
    ///
    /// A fill above target means the producer is outrunning the consumer, so the
    /// ratio drops below unity to produce fewer samples per input sample.
    pub fn update(&mut self, fill_samples: usize) -> f64 {
        let error = (fill_samples as f64 - self.target_fill) / self.target_fill;

        let unclamped = 1.0 - (KP * error + self.integral);
        let desired = unclamped.clamp(1.0 - MAX_DEVIATION, 1.0 + MAX_DEVIATION);

        // Anti-windup: only integrate while the output has authority to respond.
        if (unclamped - desired).abs() < f64::EPSILON {
            self.integral += KI * error;
            self.integral = self.integral.clamp(-MAX_DEVIATION, MAX_DEVIATION);
        }

        let delta = (desired - self.ratio).clamp(-MAX_SLEW_PER_UPDATE, MAX_SLEW_PER_UPDATE);
        self.ratio = (self.ratio + delta).clamp(1.0 - MAX_DEVIATION, 1.0 + MAX_DEVIATION);
        self.ratio
    }

    pub fn reset(&mut self) {
        self.integral = 0.0;
        self.ratio = 1.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_at_unity() {
        let c = DriftController::new(1440);
        assert_eq!(c.ratio(), 1.0);
    }

    #[test]
    fn overfull_ring_slows_production() {
        let mut c = DriftController::new(1440);
        for _ in 0..100 {
            c.update(2880); // double the target
        }
        assert!(c.ratio() < 1.0, "ratio was {}", c.ratio());
    }

    #[test]
    fn underfull_ring_speeds_production() {
        let mut c = DriftController::new(1440);
        for _ in 0..100 {
            c.update(200);
        }
        assert!(c.ratio() > 1.0, "ratio was {}", c.ratio());
    }

    #[test]
    fn ratio_never_leaves_inaudible_band() {
        let mut c = DriftController::new(1440);
        // Pathological input: ring pinned empty, then pinned full, for a long time.
        for _ in 0..100_000 {
            let r = c.update(0);
            assert!(
                (1.0 - r).abs() <= MAX_DEVIATION + 1e-12,
                "ratio {r} out of band"
            );
        }
        for _ in 0..100_000 {
            let r = c.update(100_000);
            assert!(
                (1.0 - r).abs() <= MAX_DEVIATION + 1e-12,
                "ratio {r} out of band"
            );
        }
    }

    #[test]
    fn ratio_is_slew_limited() {
        let mut c = DriftController::new(1440);
        let mut prev = c.ratio();
        for fill in [0usize, 100_000, 0, 100_000, 0] {
            for _ in 0..50 {
                let r = c.update(fill);
                assert!(
                    (r - prev).abs() <= MAX_SLEW_PER_UPDATE + 1e-12,
                    "slew {} exceeded limit",
                    (r - prev).abs()
                );
                prev = r;
            }
        }
    }

    /// Closed-loop test: the point of the controller is that a real clock mismatch
    /// converges instead of accumulating. Producer runs 0.1% fast (1000x worse than
    /// a realistic crystal mismatch); fill must settle near target and stay bounded.
    #[test]
    fn closed_loop_converges_under_clock_mismatch() {
        let target = 1440.0;
        let mut c = DriftController::new(target as usize);

        let consumer_per_tick = 480.0;
        let producer_per_tick = 480.0 * 1.001; // producer 0.1% fast

        let mut fill: f64 = target;
        // Long enough for the integral term to take out the steady-state offset.
        for _ in 0..400_000 {
            let ratio = c.update(fill.max(0.0) as usize);
            fill += producer_per_tick * ratio - consumer_per_tick;
            // A real ring cannot go negative or unbounded; clamp as one would.
            fill = fill.clamp(0.0, 100_000.0);
        }

        assert!(
            (fill - target).abs() < target * 0.25,
            "fill settled at {fill}, target {target}"
        );
        // The ratio must have found roughly 1/1.001 to balance the rates.
        let expected = consumer_per_tick / producer_per_tick;
        assert!(
            (c.ratio() - expected).abs() < 2e-4,
            "ratio {} did not approach {expected}",
            c.ratio()
        );
    }

    #[test]
    fn without_correction_the_same_mismatch_diverges() {
        // Control case establishing that the test above is measuring something:
        // with a fixed unity ratio, 0.1% mismatch runs away.
        let mut fill: f64 = 1440.0;
        for _ in 0..400_000 {
            fill += 480.0 * 1.001 - 480.0;
        }
        assert!(fill > 100_000.0, "expected divergence, got {fill}");
    }
}
