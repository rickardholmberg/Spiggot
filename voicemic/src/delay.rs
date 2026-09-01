//! Fixed delay line, allocation-free after construction.
//!
//! Needed for an honest A/B. DeepFilterNet has an algorithmic delay of
//! `(FFT_SIZE - HOP_SIZE) + lookahead * HOP_SIZE` samples: 480 (10 ms) for the LL
//! variants, 1440 (30 ms) otherwise. Comparing enhanced output against an
//! undelayed dry signal compares two different moments in time, which makes the
//! enhanced path sound wrong for reasons that have nothing to do with the model.

pub struct DelayLine {
    buf: Vec<f32>,
    pos: usize,
}

impl DelayLine {
    pub fn new(delay_samples: usize) -> Self {
        Self {
            buf: vec![0.0; delay_samples.max(1)],
            pos: 0,
        }
    }

    pub fn delay_samples(&self) -> usize {
        self.buf.len()
    }

    /// Push one sample, return the sample from `delay_samples` ago.
    #[inline]
    pub fn tick(&mut self, x: f32) -> f32 {
        let out = self.buf[self.pos];
        self.buf[self.pos] = x;
        self.pos += 1;
        if self.pos == self.buf.len() {
            self.pos = 0;
        }
        out
    }

    /// Delay a block in place. Allocation-free; safe on an audio thread.
    pub fn process(&mut self, block: &mut [f32]) {
        for s in block.iter_mut() {
            *s = self.tick(*s);
        }
    }

    pub fn reset(&mut self) {
        self.buf.fill(0.0);
        self.pos = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn impulse_emerges_after_exactly_n_samples() {
        let n = 1440; // DFN3 standard delay
        let mut d = DelayLine::new(n);
        let mut input = vec![0.0f32; n * 2];
        input[0] = 1.0;
        d.process(&mut input);
        assert_eq!(input[n], 1.0, "impulse should appear at index {n}");
        assert!(input[..n].iter().all(|&s| s == 0.0));
        assert!(input[n + 1..].iter().all(|&s| s == 0.0));
    }

    #[test]
    fn block_boundaries_do_not_shift_the_signal() {
        // Same signal delayed in one block vs many uneven blocks must match,
        // otherwise the A/B alignment depends on the audio callback size.
        let n = 480;
        let signal: Vec<f32> = (0..5000).map(|i| (i as f32 * 0.01).sin()).collect();

        let mut whole = signal.clone();
        DelayLine::new(n).process(&mut whole);

        let mut chunked = signal.clone();
        let mut d = DelayLine::new(n);
        let mut off = 0;
        for len in [1usize, 7, 480, 33, 1000, 2, 999].iter().cycle() {
            if off >= chunked.len() {
                break;
            }
            let end = (off + len).min(chunked.len());
            d.process(&mut chunked[off..end]);
            off = end;
        }
        assert_eq!(whole, chunked);
    }
}
