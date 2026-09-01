//! Real-time-safe measurement of the numbers this experiment exists to produce.
//!
//! The audio thread must never allocate, lock, or sort, so frame times land in a
//! fixed-width histogram that is updated with a single indexed increment. The
//! interesting figure is the tail, not the mean: a callback that misses its
//! deadline once a second is unusable at 20% average CPU.

/// Microseconds covered by one histogram bucket.
const BUCKET_US: u64 = 16;
/// Bucket count; `BUCKET_US * BUCKETS` = 32.768 ms of range, ~3x a 10 ms deadline.
const BUCKETS: usize = 2048;

/// Fixed-size latency histogram. Recording is allocation-free and lock-free.
#[derive(Clone)]
pub struct FrameTimes {
    buckets: Box<[u32; BUCKETS]>,
    /// Samples at or beyond the histogram range, kept so percentiles stay honest.
    overflow: u64,
    count: u64,
    sum_us: u64,
    max_us: u64,
}

impl Default for FrameTimes {
    fn default() -> Self {
        Self::new()
    }
}

impl FrameTimes {
    pub fn new() -> Self {
        Self {
            buckets: Box::new([0u32; BUCKETS]),
            overflow: 0,
            count: 0,
            sum_us: 0,
            max_us: 0,
        }
    }

    /// Record one frame's processing time. Allocation-free; safe on an audio thread.
    pub fn record_us(&mut self, us: u64) {
        let idx = (us / BUCKET_US) as usize;
        if idx < BUCKETS {
            self.buckets[idx] = self.buckets[idx].saturating_add(1);
        } else {
            self.overflow += 1;
        }
        self.count += 1;
        self.sum_us += us;
        if us > self.max_us {
            self.max_us = us;
        }
    }

    pub fn count(&self) -> u64 {
        self.count
    }

    pub fn max_us(&self) -> u64 {
        self.max_us
    }

    pub fn mean_us(&self) -> f64 {
        if self.count == 0 {
            0.0
        } else {
            self.sum_us as f64 / self.count as f64
        }
    }

    /// Upper edge of the bucket holding the given quantile, in microseconds.
    ///
    /// Returns `max_us` when the quantile falls in the overflow region, so an
    /// out-of-range tail is reported as its true value rather than silently
    /// clamped to the top of the histogram.
    pub fn percentile_us(&self, q: f64) -> u64 {
        if self.count == 0 {
            return 0;
        }
        let q = q.clamp(0.0, 1.0);
        // Rank is 1-based: the smallest sample is rank 1.
        let target = ((self.count as f64) * q).ceil().max(1.0) as u64;
        let mut cumulative = 0u64;
        for (i, &n) in self.buckets.iter().enumerate() {
            cumulative += n as u64;
            if cumulative >= target {
                return (i as u64 + 1) * BUCKET_US;
            }
        }
        self.max_us
    }

    /// Real-time factor against a fixed per-frame deadline.
    pub fn rtf(&self, deadline_us: u64) -> f64 {
        if deadline_us == 0 {
            0.0
        } else {
            self.mean_us() / deadline_us as f64
        }
    }

    pub fn reset(&mut self) {
        self.buckets.fill(0);
        self.overflow = 0;
        self.count = 0;
        self.sum_us = 0;
        self.max_us = 0;
    }
}

/// Counters for the failure modes that decide whether the bridge is usable.
#[derive(Debug, Default, Clone, Copy)]
pub struct XRuns {
    /// Output callback wanted samples the ring could not supply (audible gap).
    pub output_underruns: u64,
    /// Input callback produced samples the ring could not accept (dropped audio).
    pub input_overruns: u64,
    /// Worker missed its deadline: a frame took longer than the frame period.
    pub deadline_misses: u64,
}

impl XRuns {
    pub fn total(&self) -> u64 {
        self.output_underruns + self.input_overruns + self.deadline_misses
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_histogram_reports_zero() {
        let h = FrameTimes::new();
        assert_eq!(h.count(), 0);
        assert_eq!(h.percentile_us(0.99), 0);
        assert_eq!(h.mean_us(), 0.0);
    }

    #[test]
    fn mean_and_max_are_exact() {
        let mut h = FrameTimes::new();
        for us in [1000, 2000, 3000] {
            h.record_us(us);
        }
        assert_eq!(h.max_us(), 3000);
        assert!((h.mean_us() - 2000.0).abs() < 1e-9);
    }

    #[test]
    fn percentile_brackets_the_true_value() {
        let mut h = FrameTimes::new();
        // 99 samples at 1 ms, 1 sample at 20 ms: p99 must land on the 1 ms cluster,
        // p100 must reach the outlier.
        for _ in 0..99 {
            h.record_us(1000);
        }
        h.record_us(20_000);

        let p99 = h.percentile_us(0.99);
        assert!(
            (1000..1000 + BUCKET_US).contains(&p99),
            "p99 was {p99}, expected to bracket 1000us"
        );
        let p100 = h.percentile_us(1.0);
        assert!(p100 >= 20_000, "p100 was {p100}, expected >= 20000us");
    }

    #[test]
    fn percentile_is_monotonic() {
        let mut h = FrameTimes::new();
        for i in 0..1000u64 {
            h.record_us(i * 10);
        }
        let mut prev = 0;
        for q in [0.0, 0.1, 0.5, 0.9, 0.95, 0.99, 1.0] {
            let v = h.percentile_us(q);
            assert!(v >= prev, "percentile decreased at q={q}: {v} < {prev}");
            prev = v;
        }
    }

    #[test]
    fn overflow_samples_still_reported_in_tail() {
        let mut h = FrameTimes::new();
        for _ in 0..10 {
            h.record_us(1000);
        }
        // Far beyond the 32.7 ms histogram range.
        h.record_us(500_000);
        assert_eq!(h.max_us(), 500_000);
        assert_eq!(h.percentile_us(1.0), 500_000);
    }

    #[test]
    fn rtf_uses_the_frame_deadline() {
        let mut h = FrameTimes::new();
        for _ in 0..100 {
            h.record_us(1700); // the published deepfilter-rt mean
        }
        // 480 samples at 48 kHz = 10 ms.
        assert!((h.rtf(10_000) - 0.17).abs() < 0.01);
    }
}
