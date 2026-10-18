#![forbid(unsafe_code)]

use audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Adjustable, Async, FixedAsync, Resampler, SincInterpolationParameters};
use rustler::{Atom, Binary, Env, Error, NifResult, OwnedBinary, ResourceArc};
use std::sync::{Mutex, MutexGuard, TryLockError};

mod atoms {
    rustler::atoms! {ok, busy, poisoned, closed, allocation_failed, resample_failed}
}

struct State {
    resampler: Async<f32>,
    input: Vec<f32>,
    output: Vec<f32>,
}

struct Converter {
    input_channels: usize,
    output_channels: usize,
    chunk: usize,
    state: Mutex<Option<State>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Converter {}

fn check(condition: bool) -> NifResult<()> {
    if condition {
        Ok(())
    } else {
        Err(Error::BadArg)
    }
}

fn lock(converter: &Converter) -> NifResult<MutexGuard<'_, Option<State>>> {
    converter.state.try_lock().map_err(|error| match error {
        TryLockError::WouldBlock => Error::Term(Box::new(atoms::busy())),
        TryLockError::Poisoned(_) => Error::Term(Box::new(atoms::poisoned())),
    })
}

fn state(guard: &mut Option<State>) -> NifResult<&mut State> {
    guard
        .as_mut()
        .ok_or_else(|| Error::Term(Box::new(atoms::closed())))
}

fn failed<T: std::fmt::Display>(error: T) -> Error {
    Error::Term(Box::new((atoms::resample_failed(), error.to_string())))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn new(
    input_rate: usize,
    output_rate: usize,
    input_channels: usize,
    output_channels: usize,
    chunk: usize,
) -> NifResult<(Atom, ResourceArc<Converter>)> {
    check(
        (8000..=96000).contains(&input_rate)
            && (8000..=96000).contains(&output_rate)
            && matches!(input_channels, 1 | 2)
            && matches!(output_channels, 1 | 2)
            && (16..=input_rate / 10).contains(&chunk),
    )?;
    let resampler = Async::<f32>::new_sinc(
        output_rate as f64 / input_rate as f64,
        1.002,
        &SincInterpolationParameters::default(),
        chunk,
        output_channels,
        FixedAsync::Input,
    )
    .map_err(failed)?;
    let input = vec![0.0; chunk * output_channels];
    let output = vec![0.0; resampler.output_frames_max() * output_channels];
    Ok((
        atoms::ok(),
        ResourceArc::new(Converter {
            input_channels,
            output_channels,
            chunk,
            state: Mutex::new(Some(State {
                resampler,
                input,
                output,
            })),
        }),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn info(converter: ResourceArc<Converter>) -> NifResult<(usize, usize, usize, usize, f64)> {
    let mut guard = lock(&converter)?;
    let s = state(&mut guard)?;
    Ok((
        s.resampler.input_frames_next(),
        s.resampler.output_frames_next(),
        s.resampler.output_delay(),
        s.resampler.output_frames_max(),
        s.resampler.resample_ratio(),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn process<'a>(
    env: Env<'a>,
    converter: ResourceArc<Converter>,
    pcm: Binary<'a>,
) -> NifResult<(Atom, Binary<'a>, usize)> {
    check(pcm.len() == converter.chunk * converter.input_channels * 2)?;
    let mut guard = lock(&converter)?;
    let s = state(&mut guard)?;
    let channels = converter.output_channels;
    let output_capacity = s.resampler.output_frames_max();
    let expected_output = s.resampler.output_frames_next();
    // Allocate the BEAM result before advancing resampler state. Float scratch
    // buffers and Rubato's filter storage are reused for the whole resource.
    let mut binary = OwnedBinary::new(expected_output * channels * 2)
        .ok_or_else(|| Error::Term(Box::new(atoms::allocation_failed())))?;
    for (frame, bytes) in pcm
        .as_slice()
        .chunks_exact(converter.input_channels * 2)
        .enumerate()
    {
        let left = i16::from_le_bytes([bytes[0], bytes[1]]) as f32 / 32768.0;
        let right = if converter.input_channels == 2 {
            i16::from_le_bytes([bytes[2], bytes[3]]) as f32 / 32768.0
        } else {
            left
        };
        if channels == 1 {
            s.input[frame] = (left + right) * 0.5;
        } else {
            s.input[frame * 2] = left;
            s.input[frame * 2 + 1] = right;
        }
    }
    let input = InterleavedSlice::new(&s.input, channels, converter.chunk).map_err(failed)?;
    let mut output =
        InterleavedSlice::new_mut(&mut s.output, channels, output_capacity).map_err(failed)?;
    let (_, written) = s
        .resampler
        .process_into_buffer(&input, &mut output, None)
        .map_err(failed)?;
    check(written == expected_output)?;
    for (sample, bytes) in s.output[..written * channels]
        .iter()
        .zip(binary.as_mut_slice().chunks_exact_mut(2))
    {
        let sample = (sample * 32768.0).round().clamp(-32768.0, 32767.0) as i16;
        bytes.copy_from_slice(&sample.to_le_bytes());
    }
    Ok((atoms::ok(), binary.release(env), written))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn adjust(converter: ResourceArc<Converter>, ppm: i32) -> NifResult<Atom> {
    check((-1000..=1000).contains(&ppm))?;
    let mut guard = lock(&converter)?;
    state(&mut guard)?
        .resampler
        .set_resample_ratio_relative(1.0 + ppm as f64 / 1_000_000.0, true)
        .map_err(failed)?;
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reset(converter: ResourceArc<Converter>) -> NifResult<Atom> {
    let mut guard = lock(&converter)?;
    state(&mut guard)?.resampler.reset();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn close(converter: ResourceArc<Converter>) -> NifResult<Atom> {
    let mut guard = match converter.state.try_lock() {
        Ok(guard) => guard,
        Err(TryLockError::Poisoned(error)) => error.into_inner(),
        Err(TryLockError::WouldBlock) => return Err(Error::Term(Box::new(atoms::busy()))),
    };
    *guard = None;
    Ok(atoms::ok())
}

rustler::init!("Elixir.Parlora.Native.Resampler");
