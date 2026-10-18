use opus::{Application, Bandwidth, Bitrate, Channels, InbandFec, SampleRate};
use rustler::{Atom, Binary, Env, Error, NifResult, OwnedBinary, ResourceArc};
use std::sync::{Mutex, MutexGuard, TryLockError};

mod atoms {
    rustler::atoms! {ok, error, encoder, decoder, busy, closed_or_wrong_kind, poisoned, allocation_failed}
}

enum State {
    Encoder(opus::Encoder),
    Decoder(opus::Decoder),
}

struct Codec {
    rate: usize,
    channels: usize,
    state: Mutex<Option<State>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Codec {}

fn valid_rate(rate: usize) -> bool {
    matches!(rate, 8000 | 12000 | 16000 | 24000 | 48000)
}

fn sample_rate(rate: usize) -> NifResult<SampleRate> {
    match rate {
        8000 => Ok(SampleRate::Hz8000),
        12000 => Ok(SampleRate::Hz12000),
        16000 => Ok(SampleRate::Hz16000),
        24000 => Ok(SampleRate::Hz24000),
        48000 => Ok(SampleRate::Hz48000),
        _ => Err(Error::BadArg),
    }
}

fn check(condition: bool) -> NifResult<()> {
    if condition {
        Ok(())
    } else {
        Err(Error::BadArg)
    }
}

fn codec_error(error: opus::ErrorCode) -> Error {
    Error::Term(Box::new(error as i32))
}

fn lock(codec: &Codec) -> NifResult<MutexGuard<'_, Option<State>>> {
    codec.state.try_lock().map_err(|error| match error {
        TryLockError::WouldBlock => Error::Term(Box::new(atoms::busy())),
        TryLockError::Poisoned(_) => Error::Term(Box::new(atoms::poisoned())),
    })
}

fn closed() -> Error {
    Error::Term(Box::new(atoms::closed_or_wrong_kind()))
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut output = OwnedBinary::new(bytes.len())
        .ok_or_else(|| Error::Term(Box::new(atoms::allocation_failed())))?;
    output.as_mut_slice().copy_from_slice(bytes);
    Ok(output.release(env))
}

#[rustler::nif]
fn version() -> &'static str {
    opus::version()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn new(
    kind: Atom,
    rate: usize,
    channels: usize,
    application: i32,
) -> NifResult<(Atom, ResourceArc<Codec>)> {
    check(valid_rate(rate) && matches!(channels, 1 | 2))?;
    let mode = match application {
        2048 => Application::Voip,
        2049 => Application::Audio,
        2051 => Application::LowDelay,
        _ => return Err(Error::BadArg),
    };
    let layout = if channels == 1 {
        Channels::Mono
    } else {
        Channels::Stereo
    };
    let state = if kind == atoms::encoder() {
        State::Encoder(opus::Encoder::new(layout, sample_rate(rate)?, mode).map_err(codec_error)?)
    } else if kind == atoms::decoder() {
        State::Decoder(opus::Decoder::new(layout, sample_rate(rate)?).map_err(codec_error)?)
    } else {
        return Err(Error::BadArg);
    };
    Ok((
        atoms::ok(),
        ResourceArc::new(Codec {
            rate,
            channels,
            state: Mutex::new(Some(state)),
        }),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn configure(
    codec: ResourceArc<Codec>,
    bitrate: i32,
    complexity: i32,
    fec: i32,
    loss: i32,
    dtx: i32,
    bandwidth: i32,
) -> NifResult<Atom> {
    check(
        (500..=512000).contains(&bitrate)
            && (0..=10).contains(&complexity)
            && (0..=1).contains(&fec)
            && (0..=100).contains(&loss)
            && (0..=1).contains(&dtx),
    )?;
    let bandwidth = match bandwidth {
        1103 => Bandwidth::Wide,
        1105 => Bandwidth::Full,
        _ => return Err(Error::BadArg),
    };
    let mut guard = lock(&codec)?;
    let Some(State::Encoder(encoder)) = guard.as_mut() else {
        return Err(closed());
    };
    encoder
        .set_bitrate(Bitrate::Value(bitrate as u32))
        .map_err(codec_error)?;
    encoder
        .set_complexity(complexity as u8)
        .map_err(codec_error)?;
    encoder
        .set_inband_fec(if fec == 0 {
            InbandFec::Off
        } else {
            InbandFec::Mode1
        })
        .map_err(codec_error)?;
    encoder.set_packet_loss(loss as u8).map_err(codec_error)?;
    encoder.set_dtx(dtx != 0).map_err(codec_error)?;
    encoder.set_max_bandwidth(bandwidth).map_err(codec_error)?;
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn settings(codec: ResourceArc<Codec>) -> NifResult<(i32, i32, i32, i32, i32, i32)> {
    let mut guard = lock(&codec)?;
    let Some(State::Encoder(encoder)) = guard.as_mut() else {
        return Err(closed());
    };
    let bitrate = match encoder.get_bitrate().map_err(codec_error)? {
        Bitrate::Value(bits) => bits as i32,
        Bitrate::Auto => -1000,
        Bitrate::Max => -1,
    };
    Ok((
        bitrate,
        i32::from(encoder.get_complexity().map_err(codec_error)?),
        encoder.get_inband_fec().map_err(codec_error)? as i32,
        i32::from(encoder.get_packet_loss().map_err(codec_error)?),
        i32::from(encoder.get_dtx().map_err(codec_error)?),
        encoder.get_application().map_err(codec_error)? as i32,
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode<'a>(
    env: Env<'a>,
    codec: ResourceArc<Codec>,
    input: Binary<'a>,
    samples: usize,
) -> NifResult<(Atom, Binary<'a>)> {
    let base = codec.rate / 400;
    check(
        [1, 2, 4, 8, 16, 24]
            .iter()
            .any(|factor| samples == base * factor),
    )?;
    check(input.len() == samples * codec.channels * 2)?;
    let pcm: Vec<u16> = input
        .as_slice()
        .chunks_exact(2)
        .map(|bytes| u16::from_le_bytes([bytes[0], bytes[1]]))
        .collect();
    let mut packet = [0_u8; 4000];
    let mut guard = lock(&codec)?;
    let Some(State::Encoder(encoder)) = guard.as_mut() else {
        return Err(closed());
    };
    let size = encoder
        .encode_to_slice(&pcm, &mut packet)
        .map_err(codec_error)?;
    drop(guard);
    Ok((atoms::ok(), binary(env, &packet[..size])?))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode<'a>(
    env: Env<'a>,
    codec: ResourceArc<Codec>,
    input: Option<Binary<'a>>,
    samples: usize,
    fec: i32,
) -> NifResult<(Atom, Binary<'a>, usize)> {
    check(
        samples > 0
            && samples <= codec.rate * 120 / 1000
            && samples.is_multiple_of(codec.rate / 400)
            && (0..=1).contains(&fec)
            && !(input.is_none() && fec != 0),
    )?;
    if let Some(ref packet) = input {
        check(!packet.is_empty() && packet.len() <= 8192)?;
    }
    let packet = input.as_ref().map_or(&[][..], |bytes| bytes.as_slice());
    let mut pcm = vec![0_u16; samples * codec.channels];
    let mut guard = lock(&codec)?;
    let Some(State::Decoder(decoder)) = guard.as_mut() else {
        return Err(closed());
    };
    let count = decoder
        .decode_to_slice(packet, &mut pcm, fec != 0)
        .map_err(codec_error)?;
    drop(guard);
    let bytes: Vec<u8> = pcm[..count * codec.channels]
        .iter()
        .flat_map(|s| s.to_le_bytes())
        .collect();
    Ok((atoms::ok(), binary(env, &bytes)?, count))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn packet_info(packet: Binary<'_>, rate: usize) -> NifResult<(usize, i32, i32)> {
    check(valid_rate(rate) && !packet.is_empty() && packet.len() <= 8192)?;
    let samples =
        opus::utils::get_nb_samples(packet.as_slice(), sample_rate(rate)?).map_err(codec_error)?;
    // SAFETY: libopus receives a live immutable buffer with its exact bounded
    // length. The pointer is not retained and the function does not mutate it.
    let (channels, lbrr) = unsafe {
        (
            opus::sys::opus_packet_get_nb_channels(packet.as_slice().as_ptr()),
            opus::sys::opus_packet_has_lbrr(packet.as_slice().as_ptr(), packet.len() as i32),
        )
    };
    if lbrr < 0 {
        return Err(Error::Term(Box::new(lbrr)));
    }
    Ok((samples, channels, lbrr))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reset(codec: ResourceArc<Codec>) -> NifResult<Atom> {
    let mut guard = lock(&codec)?;
    match guard.as_mut() {
        Some(State::Encoder(encoder)) => encoder.reset().map_err(codec_error)?,
        Some(State::Decoder(decoder)) => decoder.reset().map_err(codec_error)?,
        None => return Err(closed()),
    }
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn close(codec: ResourceArc<Codec>) -> NifResult<Atom> {
    // A caught panic while holding the lock poisons it. Drop the codec without
    // reusing that state; cleanup must still be possible and idempotent.
    let mut guard = match codec.state.try_lock() {
        Ok(guard) => guard,
        Err(TryLockError::Poisoned(error)) => error.into_inner(),
        Err(TryLockError::WouldBlock) => return Err(Error::Term(Box::new(atoms::busy()))),
    };
    *guard = None;
    Ok(atoms::ok())
}

// Validation-only fault hooks. Environment gate requires an explicit isolated
// probe invocation; these functions are not a proposed production API.
fn fault_enabled() -> NifResult<()> {
    check(std::env::var("PARLORA_ISOLATED_FAULT_PROBE").as_deref() == Ok("1"))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn inject_panic() -> NifResult<Atom> {
    fault_enabled()?;
    panic!("intentional isolated Rustler panic")
}

#[rustler::nif(schedule = "DirtyCpu")]
fn inject_resource_panic(codec: ResourceArc<Codec>) -> NifResult<Atom> {
    fault_enabled()?;
    let _guard = lock(&codec)?;
    panic!("intentional isolated resource panic")
}

#[rustler::nif(schedule = "DirtyCpu")]
fn inject_abort() -> NifResult<Atom> {
    fault_enabled()?;
    std::process::abort()
}

rustler::init!("Elixir.OpusProbe");
