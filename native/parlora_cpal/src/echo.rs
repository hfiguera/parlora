use crate::{atoms, check, fail};
use aec3::voip::VoipAec3;
use rustler::{Atom, Binary, Env, NifResult, OwnedBinary, ResourceArc};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::time::Duration;

const FRAME: usize = 240;
type Samples = [f32; FRAME];

enum Message {
    Render(Samples),
    Capture(Samples, SyncSender<Result<Samples, String>>),
    Close,
}

struct Echo(SyncSender<Message>);

#[rustler::resource_impl]
impl rustler::Resource for Echo {}

#[rustler::nif(schedule = "DirtyIo")]
fn echo_new() -> NifResult<(Atom, ResourceArc<Echo>)> {
    let (sender, receiver) = mpsc::sync_channel(12);
    let (ready, startup) = mpsc::sync_channel(1);
    // AEC3's DSP state is thread-bound. The resource owns only the bounded sender.
    std::thread::Builder::new()
        .name("parlora-echo".into())
        .spawn(move || worker(receiver, ready))
        .map_err(fail)?;
    startup
        .recv_timeout(Duration::from_secs(2))
        .map_err(fail)?
        .map_err(fail)?;
    Ok((atoms::ok(), ResourceArc::new(Echo(sender))))
}

fn new_filter() -> Result<VoipAec3, aec3::voip::VoipAec3Error> {
    VoipAec3::builder(24_000, 1, 1)
        .enable_high_pass(false)
        .build()
}

fn worker(receiver: Receiver<Message>, ready: SyncSender<Result<(), String>>) {
    let mut filter = match new_filter() {
        Ok(filter) => filter,
        Err(error) => {
            let _ = ready.send(Err(error.to_string()));
            return;
        }
    };
    if ready.send(Ok(())).is_err() {
        return;
    }

    while let Ok(message) = receiver.recv() {
        match message {
            Message::Render(frame) => {
                if filter.handle_render_frame(&frame).is_err() {
                    break;
                }
            }
            Message::Capture(frame, sender) => {
                let mut output = [0.0; FRAME];
                let result = filter
                    .process_capture_frame(&frame, false, &mut output)
                    .map(|_| output)
                    .map_err(|error| error.to_string());
                let _ = sender.send(result);
            }
            Message::Close => break,
        }
    }
}

#[rustler::nif]
fn echo_close(echo: ResourceArc<Echo>) -> Atom {
    let _ = echo.0.try_send(Message::Close);
    atoms::ok()
}

#[rustler::nif]
fn echo_render(echo: ResourceArc<Echo>, pcm: Binary) -> NifResult<Atom> {
    check(pcm.len() == FRAME * 2)?;
    echo.0
        .try_send(Message::Render(samples(pcm)))
        .map_err(fail)?;
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyIo")]
fn echo_capture<'a>(
    env: Env<'a>,
    echo: ResourceArc<Echo>,
    pcm: Binary,
) -> NifResult<(Atom, Binary<'a>)> {
    check(pcm.len() == FRAME * 2)?;
    let (sender, receiver) = mpsc::sync_channel(1);
    echo.0
        .try_send(Message::Capture(samples(pcm), sender))
        .map_err(fail)?;
    let output = receiver
        .recv_timeout(Duration::from_millis(50))
        .map_err(fail)?
        .map_err(fail)?;

    let mut binary = OwnedBinary::new(FRAME * 2).ok_or_else(|| fail("echo allocation"))?;
    for (bytes, sample) in binary.as_mut_slice().chunks_exact_mut(2).zip(output) {
        bytes.copy_from_slice(&pcm_sample(sample).to_le_bytes());
    }
    Ok((atoms::ok(), binary.release(env)))
}

fn samples(pcm: Binary) -> Samples {
    let mut frame = [0.0; FRAME];
    for (sample, bytes) in frame.iter_mut().zip(pcm.as_slice().chunks_exact(2)) {
        *sample = f32::from(i16::from_le_bytes([bytes[0], bytes[1]])) / 32768.0;
    }
    frame
}

pub(crate) fn pcm_sample(sample: f32) -> i16 {
    (sample * 32768.0).round().clamp(-32768.0, 32767.0) as i16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suppresses_delayed_playback_and_preserves_capture_without_playback() {
        let mut filter = new_filter().unwrap();
        let mut rng = 9u32;
        let mut smoothed = 0.0;
        let reference: Vec<Samples> = (0..200)
            .map(|_| {
                std::array::from_fn(|_| {
                    rng = rng.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                    smoothed = 0.65 * smoothed + 0.35 * ((rng >> 16) as f32 / 32768.0 - 1.0);
                    smoothed
                })
            })
            .collect();
        let silence = [0.0; FRAME];
        let mut before = 0.0;
        let mut after = 0.0;

        for (i, frame) in reference.iter().enumerate() {
            let capture = if i >= 6 {
                reference[i - 6].map(|value| 0.35 * value)
            } else {
                silence
            };
            let mut clean = silence;
            filter
                .process(&capture, Some(frame), false, &mut clean)
                .unwrap();
            if i >= 100 {
                before += capture.iter().map(|sample| sample * sample).sum::<f32>();
                after += clean.iter().map(|sample| sample * sample).sum::<f32>();
            }
        }
        assert!(after < before * 0.1, "echo energy ratio {}", after / before);

        let capture = reference[0];
        for _ in 0..60 {
            let mut clean = silence;
            filter
                .process(&capture, Some(&silence), false, &mut clean)
                .unwrap();
        }
        let mut clean = silence;
        filter
            .process(&capture, Some(&silence), false, &mut clean)
            .unwrap();
        let before = capture.iter().map(|sample| sample * sample).sum::<f32>();
        let after = clean.iter().map(|sample| sample * sample).sum::<f32>();
        assert!(
            after > before * 0.7,
            "near-end energy ratio {}",
            after / before
        );
    }
}
