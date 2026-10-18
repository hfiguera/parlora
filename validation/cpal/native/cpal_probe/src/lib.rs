#![forbid(unsafe_code)]
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use crossbeam_queue::ArrayQueue;
use rustler::{
    Atom, Binary, Env, Error, LocalPid, Monitor, NifMap, NifResult, OwnedBinary, ResourceArc,
};
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering::Relaxed},
    mpsc, Arc,
};
use std::time::{Duration, Instant};

mod atoms {
    rustler::atoms! {ok, closed, allocation_failed, timeout}
}
fn fail(e: impl ToString) -> Error {
    Error::Term(Box::new(e.to_string()))
}
fn check(b: bool) -> NifResult<()> {
    if b {
        Ok(())
    } else {
        Err(Error::BadArg)
    }
}

#[derive(NifMap)]
struct DeviceInfo {
    id: String,
    name: String,
    input: Option<(u32, u16, String)>,
    output: Option<(u32, u16, String)>,
}
fn host(name: &str) -> Result<cpal::Host, String> {
    let id = cpal::available_hosts()
        .into_iter()
        .find(|id| id.name().eq_ignore_ascii_case(name))
        .ok_or("unknown host")?;
    cpal::host_from_id(id).map_err(|e| e.to_string())
}
fn config_info(c: cpal::SupportedStreamConfig) -> (u32, u16, String) {
    (c.sample_rate(), c.channels(), c.sample_format().to_string())
}
#[rustler::nif(schedule = "DirtyIo")]
fn devices(name: String) -> NifResult<Vec<DeviceInfo>> {
    host(&name)
        .map_err(fail)?
        .devices()
        .map_err(fail)?
        .map(|d| {
            Ok(DeviceInfo {
                id: d.id().map_err(fail)?.to_string(),
                name: d.description().map_err(fail)?.name().to_owned(),
                input: d.default_input_config().ok().map(config_info),
                output: d.default_output_config().ok().map(config_info),
            })
        })
        .collect()
}

struct Shared {
    input: ArrayQueue<[f32; 2]>,
    output: ArrayQueue<[f32; 2]>,
    stop: AtomicBool,
    stopped: AtomicBool,
    input_channels: AtomicUsize,
    output_channels: AtomicUsize,
    input_rate: AtomicUsize,
    output_rate: AtomicUsize,
    input_callbacks: AtomicUsize,
    output_callbacks: AtomicUsize,
    captured: AtomicUsize,
    rendered: AtomicUsize,
    dropped: AtomicUsize,
    underrun: AtomicUsize,
    errors: AtomicUsize,
}
impl Shared {
    fn new(capacity: usize) -> Self {
        Self {
            input: ArrayQueue::new(capacity),
            output: ArrayQueue::new(capacity),
            stop: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            input_channels: AtomicUsize::new(1),
            output_channels: AtomicUsize::new(2),
            input_rate: AtomicUsize::new(48000),
            output_rate: AtomicUsize::new(48000),
            input_callbacks: AtomicUsize::new(0),
            output_callbacks: AtomicUsize::new(0),
            captured: AtomicUsize::new(0),
            rendered: AtomicUsize::new(0),
            dropped: AtomicUsize::new(0),
            underrun: AtomicUsize::new(0),
            errors: AtomicUsize::new(0),
        }
    }
    fn capture<T: cpal::Sample>(&self, data: &[T], channels: usize)
    where
        f32: cpal::FromSample<T>,
    {
        self.input_callbacks.fetch_add(1, Relaxed);
        for frame in data.chunks_exact(channels) {
            let value = [
                frame[0].to_sample::<f32>(),
                if channels == 2 {
                    frame[1].to_sample::<f32>()
                } else {
                    0.0
                },
            ];
            if self.input.push(value).is_err() {
                self.dropped.fetch_add(1, Relaxed);
            }
            self.captured.fetch_add(1, Relaxed);
        }
    }
    fn render<T: cpal::Sample + cpal::FromSample<f32>>(&self, data: &mut [T], channels: usize) {
        self.output_callbacks.fetch_add(1, Relaxed);
        for frame in data.chunks_exact_mut(channels) {
            let value = self.output.pop().unwrap_or_else(|| {
                self.underrun.fetch_add(1, Relaxed);
                [0.0; 2]
            });
            for (target, source) in frame.iter_mut().zip(value) {
                *target = T::from_sample(source);
            }
            self.rendered.fetch_add(1, Relaxed);
        }
    }
}
struct Session {
    shared: Arc<Shared>,
}
#[rustler::resource_impl]
impl rustler::Resource for Session {
    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        self.shared.stop.store(true, Relaxed);
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.shared.stop.store(true, Relaxed);
    }
}
struct StopGuard(Arc<Shared>);
impl Drop for StopGuard {
    fn drop(&mut self) {
        self.0.stopped.store(true, Relaxed);
    }
}

fn input_stream<T: cpal::SizedSample>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    s: Arc<Shared>,
) -> Result<cpal::Stream, String>
where
    f32: cpal::FromSample<T>,
{
    let channels = config.channels as usize;
    let errors = s.clone();
    device
        .build_input_stream(
            config,
            move |data: &[T], _| s.capture(data, channels),
            move |_| {
                errors.errors.fetch_add(1, Relaxed);
            },
            Some(Duration::from_secs(2)),
        )
        .map_err(|e| e.to_string())
}
fn output_stream<T: cpal::SizedSample + cpal::FromSample<f32>>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    s: Arc<Shared>,
) -> Result<cpal::Stream, String> {
    let channels = config.channels as usize;
    let errors = s.clone();
    device
        .build_output_stream(
            config,
            move |data: &mut [T], _| s.render(data, channels),
            move |_| {
                errors.errors.fetch_add(1, Relaxed);
            },
            Some(Duration::from_secs(2)),
        )
        .map_err(|e| e.to_string())
}
fn streams(
    name: &str,
    input_id: &str,
    output_id: &str,
    s: &Arc<Shared>,
) -> Result<(cpal::Stream, cpal::Stream), String> {
    let h = host(name)?;
    let input = h
        .devices()
        .map_err(|e| e.to_string())?
        .find(|d| d.id().is_ok_and(|id| id.to_string() == input_id))
        .ok_or("input device not found")?;
    let output = h
        .devices()
        .map_err(|e| e.to_string())?
        .find(|d| d.id().is_ok_and(|id| id.to_string() == output_id))
        .ok_or("output device not found")?;
    let ic = input.default_input_config().map_err(|e| e.to_string())?;
    let oc = output.default_output_config().map_err(|e| e.to_string())?;
    if !(1..=2).contains(&ic.channels()) || !(1..=2).contains(&oc.channels()) {
        return Err("probe supports mono/stereo devices".into());
    }
    s.input_channels.store(ic.channels() as usize, Relaxed);
    s.output_channels.store(oc.channels() as usize, Relaxed);
    s.input_rate.store(ic.sample_rate() as usize, Relaxed);
    s.output_rate.store(oc.sample_rate() as usize, Relaxed);
    // Request a 10 ms device buffer; backend defaults can buffer seconds of audio.
    let mut input_config = ic.config();
    input_config.buffer_size = cpal::BufferSize::Fixed(ic.sample_rate() / 100);
    let mut output_config = oc.config();
    output_config.buffer_size = cpal::BufferSize::Fixed(oc.sample_rate() / 100);
    let istream = match ic.sample_format() {
        cpal::SampleFormat::F32 => input_stream::<f32>(&input, input_config, s.clone()),
        cpal::SampleFormat::I16 => input_stream::<i16>(&input, input_config, s.clone()),
        cpal::SampleFormat::I32 => input_stream::<i32>(&input, input_config, s.clone()),
        other => Err(format!("unsupported input format: {other}")),
    }?;
    let ostream = match oc.sample_format() {
        cpal::SampleFormat::F32 => output_stream::<f32>(&output, output_config, s.clone()),
        cpal::SampleFormat::I16 => output_stream::<i16>(&output, output_config, s.clone()),
        cpal::SampleFormat::I32 => output_stream::<i32>(&output, output_config, s.clone()),
        other => Err(format!("unsupported output format: {other}")),
    }?;
    istream.play().map_err(|e| e.to_string())?;
    ostream.play().map_err(|e| e.to_string())?;
    Ok((istream, ostream))
}
fn start(
    env: Env,
    name: String,
    input: String,
    output: String,
    capacity: usize,
    synthetic: bool,
) -> NifResult<(Atom, ResourceArc<Session>)> {
    check((16..=48000).contains(&capacity))?;
    let shared = Arc::new(Shared::new(capacity));
    let worker = shared.clone();
    let (tx, rx) = mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name("parlora-cpal-probe".into())
        .spawn(move || {
            let _guard = StopGuard(worker.clone());
            // CPAL stream creation and destruction stay on this native owner thread.
            let live = if synthetic {
                None
            } else {
                match streams(&name, &input, &output, &worker) {
                    Ok(streams) => Some(streams),
                    Err(error) => {
                        let _ = tx.send(Err(error));
                        return;
                    }
                }
            };
            if tx.send(Ok(())).is_err() {
                return;
            }
            let input = [0.25f32; 480];
            let mut output = [0.0f32; 960];
            while !worker.stop.load(Relaxed) {
                if synthetic {
                    worker.capture(&input, 1);
                    worker.render(&mut output, 2);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            drop(live);
        })
        .map_err(fail)?;
    match rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(())) => (),
        Ok(Err(e)) => return Err(fail(e)),
        Err(_) => {
            shared.stop.store(true, Relaxed);
            return Err(Error::Term(Box::new(atoms::timeout())));
        }
    }
    let resource = ResourceArc::new(Session { shared });
    if resource.monitor(Some(env), &env.pid()).is_none() {
        return Err(fail("owner monitor failed"));
    }
    Ok((atoms::ok(), resource))
}
#[rustler::nif(schedule = "DirtyIo")]
fn open(
    env: Env,
    name: String,
    input: String,
    output: String,
    capacity: usize,
) -> NifResult<(Atom, ResourceArc<Session>)> {
    start(env, name, input, output, capacity, false)
}
#[rustler::nif(schedule = "DirtyIo")]
fn open_test(env: Env, capacity: usize) -> NifResult<(Atom, ResourceArc<Session>)> {
    start(
        env,
        String::new(),
        String::new(),
        String::new(),
        capacity,
        true,
    )
}
#[derive(NifMap)]
struct Stats {
    input_rate: usize,
    output_rate: usize,
    input_channels: usize,
    output_channels: usize,
    input_callbacks: usize,
    output_callbacks: usize,
    captured: usize,
    rendered: usize,
    dropped: usize,
    underrun: usize,
    errors: usize,
    input_queued: usize,
    output_queued: usize,
    stopped: bool,
}
#[rustler::nif]
fn stats(r: ResourceArc<Session>) -> Stats {
    let s = &r.shared;
    Stats {
        input_rate: s.input_rate.load(Relaxed),
        output_rate: s.output_rate.load(Relaxed),
        input_channels: s.input_channels.load(Relaxed),
        output_channels: s.output_channels.load(Relaxed),
        input_callbacks: s.input_callbacks.load(Relaxed),
        output_callbacks: s.output_callbacks.load(Relaxed),
        captured: s.captured.load(Relaxed),
        rendered: s.rendered.load(Relaxed),
        dropped: s.dropped.load(Relaxed),
        underrun: s.underrun.load(Relaxed),
        errors: s.errors.load(Relaxed),
        input_queued: s.input.len(),
        output_queued: s.output.len(),
        stopped: s.stopped.load(Relaxed),
    }
}
fn active(s: &Shared) -> NifResult<()> {
    if s.stop.load(Relaxed) || s.stopped.load(Relaxed) {
        Err(Error::Term(Box::new(atoms::closed())))
    } else {
        Ok(())
    }
}
#[rustler::nif(schedule = "DirtyCpu")]
fn read<'a>(
    env: Env<'a>,
    r: ResourceArc<Session>,
    frames: usize,
) -> NifResult<(Atom, Binary<'a>, usize)> {
    let s = &r.shared;
    check(frames > 0 && frames <= s.input.capacity())?;
    active(s)?;
    let channels = s.input_channels.load(Relaxed);
    let count = frames.min(s.input.len());
    let mut binary = OwnedBinary::new(count * channels * 2)
        .ok_or_else(|| Error::Term(Box::new(atoms::allocation_failed())))?;
    let mut copied = 0;
    for frame in binary.as_mut_slice().chunks_exact_mut(channels * 2) {
        let Some(value) = s.input.pop() else {
            break;
        };
        for (sample, bytes) in value.iter().zip(frame.chunks_exact_mut(2)) {
            bytes.copy_from_slice(
                &((sample * 32768.0).round().clamp(-32768.0, 32767.0) as i16).to_le_bytes(),
            );
        }
        copied += 1;
    }
    binary.realloc_or_copy(copied * channels * 2);
    Ok((atoms::ok(), binary.release(env), copied))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn write(r: ResourceArc<Session>, pcm: Binary) -> NifResult<(Atom, usize)> {
    let s = &r.shared;
    active(s)?;
    let channels = s.output_channels.load(Relaxed);
    check(
        !pcm.is_empty()
            && pcm.len().is_multiple_of(channels * 2)
            && pcm.len() <= s.output.capacity() * channels * 2,
    )?;
    let mut written = 0;
    for bytes in pcm.as_slice().chunks_exact(channels * 2) {
        let mut frame = [0.0; 2];
        for (value, sample) in frame.iter_mut().zip(bytes.chunks_exact(2)) {
            *value = i16::from_le_bytes([sample[0], sample[1]]) as f32 / 32768.0;
        }
        if s.output.push(frame).is_err() {
            break;
        }
        written += 1;
    }
    Ok((atoms::ok(), written))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn clear(r: ResourceArc<Session>) -> NifResult<usize> {
    let s = &r.shared;
    active(s)?;
    let mut count = 0;
    for _ in 0..s.output.capacity() {
        if s.output.pop().is_none() {
            break;
        }
        count += 1;
    }
    Ok(count)
}
#[rustler::nif(schedule = "DirtyIo")]
fn close(r: ResourceArc<Session>) -> NifResult<Atom> {
    r.shared.stop.store(true, Relaxed);
    let deadline = Instant::now() + Duration::from_secs(3);
    while !r.shared.stopped.load(Relaxed) {
        if Instant::now() > deadline {
            return Err(Error::Term(Box::new(atoms::timeout())));
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    Ok(atoms::ok())
}
rustler::init!("Elixir.DeviceProbe");

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn callback_overflow_and_silence() {
        let s = Shared::new(2);
        s.capture(&[0.25f32, 0.5, 0.75], 1);
        assert_eq!(s.input.len(), 2);
        assert_eq!(s.dropped.load(Relaxed), 1);
        s.output.push([0.25, -0.25]).unwrap();
        let mut output = [9.0f32; 4];
        s.render(&mut output, 2);
        assert_eq!(output, [0.25, -0.25, 0.0, 0.0]);
        assert_eq!(s.underrun.load(Relaxed), 1);
    }
    #[test]
    fn callback_frames_keep_channels_together() {
        let s = Shared::new(2);
        s.capture(&[1000i16, -1000, 2000, -2000], 2);
        assert_eq!(
            s.input.pop().unwrap(),
            [1000.0 / 32768.0, -1000.0 / 32768.0]
        );
        assert_eq!(
            s.input.pop().unwrap(),
            [2000.0 / 32768.0, -2000.0 / 32768.0]
        );
    }
}
