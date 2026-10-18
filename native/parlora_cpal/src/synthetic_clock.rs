use std::time::Duration;

const PERIOD: Duration = Duration::from_millis(10);
const MAX_BATCH: u32 = 5;

/// Schedule 480-frame blocks against elapsed time at 48 kHz. Late wakeups must
/// not permanently slow the device clock. Catch-up uses fixed-size batches;
/// the owner checks stop between blocks and yields between overdue batches.
pub(crate) struct SyntheticClock {
    next: Duration,
}

impl SyntheticClock {
    pub(crate) fn new() -> Self {
        Self { next: PERIOD }
    }

    pub(crate) fn due(&mut self, elapsed: Duration) -> u32 {
        if elapsed < self.next {
            return 0;
        }
        let count = ((elapsed - self.next).as_nanos() / PERIOD.as_nanos() + 1)
            .min(u128::from(MAX_BATCH)) as u32;
        self.next += PERIOD * count;
        count
    }

    pub(crate) fn wait(&self, elapsed: Duration) -> Duration {
        self.next.saturating_sub(elapsed).min(PERIOD)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delayed_wakeups_preserve_the_sample_clock() {
        let mut clock = SyntheticClock::new();
        let mut elapsed = Duration::ZERO;
        let mut blocks = 0;
        for _ in 0..600 {
            // Simulate sleep overshoot plus callback work on every iteration.
            elapsed += clock.wait(elapsed) + Duration::from_micros(1_700);
            blocks += clock.due(elapsed);
            assert_eq!(u128::from(blocks), elapsed.as_millis() / 10);
            elapsed += Duration::from_micros(300);
        }
        assert_eq!(blocks, 600);
        assert!(elapsed < Duration::from_millis(6_010));
    }

    #[test]
    fn long_stall_catches_up_in_bounded_batches_without_skipping_frames() {
        let mut clock = SyntheticClock::new();
        let elapsed = Duration::from_millis(3_007);
        for _ in 0..59 {
            assert_eq!(clock.due(elapsed), MAX_BATCH);
            assert_eq!(clock.wait(elapsed), Duration::ZERO);
        }
        assert_eq!(clock.due(elapsed), MAX_BATCH);
        assert_eq!(clock.due(elapsed), 0);
        assert_eq!(clock.wait(elapsed), Duration::from_millis(3));
        assert_eq!(clock.due(Duration::from_millis(3_010)), 1);
    }

    #[test]
    fn early_wakeups_do_not_render_future_audio() {
        let mut clock = SyntheticClock::new();
        assert_eq!(clock.due(Duration::ZERO), 0);
        assert_eq!(clock.due(Duration::from_millis(9)), 0);
        assert_eq!(
            clock.wait(Duration::from_millis(9)),
            Duration::from_millis(1)
        );
        assert_eq!(clock.due(Duration::from_millis(10)), 1);
        assert_eq!(clock.due(Duration::from_millis(10)), 0);
    }
}
