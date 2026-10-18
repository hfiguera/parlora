/* Validation-only binding: explicit PCM16 little-endian, bounded buffers,
 * resource lifetime management, and nonblocking exclusive native-state access.
 * This is a feasibility probe, not a production library. */
#include <erl_nif.h>
#include <opus.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  OpusEncoder *encoder;
  OpusDecoder *decoder;
  ErlNifMutex *mutex;
  int rate;
  int channels;
} Codec;

static ErlNifResourceType *codec_type;
static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) {
  return enif_make_atom(env, name);
}
static ERL_NIF_TERM error(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}
static ERL_NIF_TERM opus_error(ErlNifEnv *env, int code) {
  return enif_make_tuple2(env, atom(env, "error"), enif_make_int(env, code));
}
static int valid_rate(int rate) {
  return rate == 8000 || rate == 12000 || rate == 16000 || rate == 24000 || rate == 48000;
}
static void destroy(Codec *codec) {
  if (codec->encoder) opus_encoder_destroy(codec->encoder);
  if (codec->decoder) opus_decoder_destroy(codec->decoder);
  codec->encoder = NULL;
  codec->decoder = NULL;
}
static void destructor(ErlNifEnv *env, void *object) {
  (void)env;
  Codec *codec = object;
  destroy(codec);
  if (codec->mutex) enif_mutex_destroy(codec->mutex);
}
static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv; (void)info;
  codec_type = enif_open_resource_type(env, NULL, "opus_probe_codec", destructor,
                                      ERL_NIF_RT_CREATE, NULL);
  return codec_type ? 0 : -1;
}
static ERL_NIF_TERM version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc; (void)argv;
  return enif_make_string(env, opus_get_version_string(), ERL_NIF_LATIN1);
}
static ERL_NIF_TERM create(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  int rate, channels, application, result;
  int encoder = enif_is_identical(argv[0], atom(env, "encoder"));
  int decoder = enif_is_identical(argv[0], atom(env, "decoder"));
  if ((!encoder && !decoder) || !enif_get_int(env, argv[1], &rate) || !valid_rate(rate) ||
      !enif_get_int(env, argv[2], &channels) || channels < 1 || channels > 2 ||
      !enif_get_int(env, argv[3], &application) ||
      (application != OPUS_APPLICATION_VOIP && application != OPUS_APPLICATION_AUDIO &&
       application != OPUS_APPLICATION_RESTRICTED_LOWDELAY)) return enif_make_badarg(env);
  Codec *codec = enif_alloc_resource(codec_type, sizeof(*codec));
  if (!codec) return error(env, "allocation_failed");
  memset(codec, 0, sizeof(*codec));
  codec->rate = rate;
  codec->channels = channels;
  codec->mutex = enif_mutex_create("opus_probe_codec");
  if (!codec->mutex) { enif_release_resource(codec); return error(env, "allocation_failed"); }
  if (encoder) codec->encoder = opus_encoder_create(rate, channels, application, &result);
  else codec->decoder = opus_decoder_create(rate, channels, &result);
  if (result != OPUS_OK) { enif_release_resource(codec); return opus_error(env, result); }
  ERL_NIF_TERM ref = enif_make_resource(env, codec);
  enif_release_resource(codec);
  return enif_make_tuple2(env, atom(env, "ok"), ref);
}
static ERL_NIF_TERM configure(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Codec *codec;
  int bitrate, complexity, fec, loss, dtx, bandwidth;
  if (!enif_get_resource(env, argv[0], codec_type, (void **)&codec) ||
      !enif_get_int(env, argv[1], &bitrate) || bitrate < 500 || bitrate > 512000 ||
      !enif_get_int(env, argv[2], &complexity) || complexity < 0 || complexity > 10 ||
      !enif_get_int(env, argv[3], &fec) || fec < 0 || fec > 1 ||
      !enif_get_int(env, argv[4], &loss) || loss < 0 || loss > 100 ||
      !enif_get_int(env, argv[5], &dtx) || dtx < 0 || dtx > 1 ||
      !enif_get_int(env, argv[6], &bandwidth) ||
      (bandwidth != OPUS_BANDWIDTH_WIDEBAND && bandwidth != OPUS_BANDWIDTH_FULLBAND))
    return enif_make_badarg(env);
  if (enif_mutex_trylock(codec->mutex)) return error(env, "busy");
  if (!codec->encoder) { enif_mutex_unlock(codec->mutex); return error(env, "closed_or_wrong_kind"); }
  int result = opus_encoder_ctl(codec->encoder, OPUS_SET_BITRATE(bitrate));
  if (result == OPUS_OK) result = opus_encoder_ctl(codec->encoder, OPUS_SET_COMPLEXITY(complexity));
  if (result == OPUS_OK) result = opus_encoder_ctl(codec->encoder, OPUS_SET_INBAND_FEC(fec));
  if (result == OPUS_OK) result = opus_encoder_ctl(codec->encoder, OPUS_SET_PACKET_LOSS_PERC(loss));
  if (result == OPUS_OK) result = opus_encoder_ctl(codec->encoder, OPUS_SET_DTX(dtx));
  if (result == OPUS_OK) result = opus_encoder_ctl(codec->encoder, OPUS_SET_MAX_BANDWIDTH(bandwidth));
  enif_mutex_unlock(codec->mutex);
  return result == OPUS_OK ? atom(env, "ok") : opus_error(env, result);
}
static ERL_NIF_TERM settings(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Codec *codec;
  if (!enif_get_resource(env, argv[0], codec_type, (void **)&codec)) return enif_make_badarg(env);
  if (enif_mutex_trylock(codec->mutex)) return error(env, "busy");
  if (!codec->encoder) { enif_mutex_unlock(codec->mutex); return error(env, "closed_or_wrong_kind"); }
  opus_int32 bitrate = 0, complexity = 0, fec = 0, loss = 0, dtx = 0, application = 0;
  opus_encoder_ctl(codec->encoder, OPUS_GET_BITRATE(&bitrate));
  opus_encoder_ctl(codec->encoder, OPUS_GET_COMPLEXITY(&complexity));
  opus_encoder_ctl(codec->encoder, OPUS_GET_INBAND_FEC(&fec));
  opus_encoder_ctl(codec->encoder, OPUS_GET_PACKET_LOSS_PERC(&loss));
  opus_encoder_ctl(codec->encoder, OPUS_GET_DTX(&dtx));
  opus_encoder_ctl(codec->encoder, OPUS_GET_APPLICATION(&application));
  enif_mutex_unlock(codec->mutex);
  return enif_make_tuple6(env, enif_make_int(env, bitrate), enif_make_int(env, complexity),
    enif_make_int(env, fec), enif_make_int(env, loss), enif_make_int(env, dtx), enif_make_int(env, application));
}
static ERL_NIF_TERM encode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Codec *codec;
  ErlNifBinary input;
  int samples;
  if (!enif_get_resource(env, argv[0], codec_type, (void **)&codec) ||
      !enif_inspect_binary(env, argv[1], &input) || !enif_get_int(env, argv[2], &samples))
    return enif_make_badarg(env);
  int base = codec->rate / 400;
  if (samples != base && samples != base * 2 && samples != base * 4 &&
      samples != base * 8 && samples != base * 16 && samples != base * 24)
    return enif_make_badarg(env);
  size_t count = (size_t)samples * codec->channels;
  if (input.size != count * 2) return enif_make_badarg(env);
  opus_int16 pcm[5760];
  for (size_t i = 0; i < count; i++) {
    int value = input.data[2*i] | ((int)input.data[2*i+1] << 8);
    pcm[i] = (opus_int16)(value >= 32768 ? value - 65536 : value);
  }
  unsigned char packet[4000];
  if (enif_mutex_trylock(codec->mutex)) return error(env, "busy");
  if (!codec->encoder) { enif_mutex_unlock(codec->mutex); return error(env, "closed_or_wrong_kind"); }
  int result = opus_encode(codec->encoder, pcm, samples, packet, sizeof(packet));
  enif_mutex_unlock(codec->mutex);
  if (result < 0) return opus_error(env, result);
  ERL_NIF_TERM output;
  unsigned char *bytes = enif_make_new_binary(env, (size_t)result, &output);
  if (!bytes) return error(env, "allocation_failed");
  memcpy(bytes, packet, (size_t)result);
  return enif_make_tuple2(env, atom(env, "ok"), output);
}
static ERL_NIF_TERM decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Codec *codec;
  ErlNifBinary input;
  int samples, fec;
  int plc = enif_is_identical(argv[1], atom(env, "nil"));
  if (!enif_get_resource(env, argv[0], codec_type, (void **)&codec) ||
      !enif_get_int(env, argv[2], &samples) || samples <= 0 || samples > codec->rate * 120 / 1000 ||
      samples % (codec->rate / 400) != 0 || !enif_get_int(env, argv[3], &fec) || fec < 0 || fec > 1 ||
      (plc && fec) || (!plc && (!enif_inspect_binary(env, argv[1], &input) ||
                              input.size == 0 || input.size > 8192))) return enif_make_badarg(env);
  opus_int16 pcm[11520];
  if (enif_mutex_trylock(codec->mutex)) return error(env, "busy");
  if (!codec->decoder) { enif_mutex_unlock(codec->mutex); return error(env, "closed_or_wrong_kind"); }
  int result = opus_decode(codec->decoder, plc ? NULL : input.data, plc ? 0 : (int)input.size,
                           pcm, samples, fec);
  enif_mutex_unlock(codec->mutex);
  if (result < 0) return opus_error(env, result);
  ERL_NIF_TERM output;
  size_t count = (size_t)result * codec->channels;
  unsigned char *bytes = enif_make_new_binary(env, count * 2, &output);
  if (!bytes) return error(env, "allocation_failed");
  for (size_t i = 0; i < count; i++) {
    uint16_t value = (uint16_t)pcm[i];
    bytes[2*i] = (unsigned char)value;
    bytes[2*i+1] = (unsigned char)(value >> 8);
  }
  return enif_make_tuple3(env, atom(env, "ok"), output, enif_make_int(env, result));
}
static ERL_NIF_TERM packet_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary input;
  int rate;
  if (!enif_inspect_binary(env, argv[0], &input) || input.size == 0 || input.size > 8192 ||
      !enif_get_int(env, argv[1], &rate) || !valid_rate(rate)) return enif_make_badarg(env);
  int samples = opus_packet_get_nb_samples(input.data, (opus_int32)input.size, rate);
  if (samples < 0) return opus_error(env, samples);
  int lbrr = opus_packet_has_lbrr(input.data, (opus_int32)input.size);
  if (lbrr < 0) return opus_error(env, lbrr);
  return enif_make_tuple3(env, enif_make_int(env, samples),
    enif_make_int(env, opus_packet_get_nb_channels(input.data)), enif_make_int(env, lbrr));
}
static ERL_NIF_TERM reset(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Codec *codec;
  if (!enif_get_resource(env, argv[0], codec_type, (void **)&codec)) return enif_make_badarg(env);
  if (enif_mutex_trylock(codec->mutex)) return error(env, "busy");
  if (!codec->encoder && !codec->decoder) {
    enif_mutex_unlock(codec->mutex); return error(env, "closed_or_wrong_kind");
  }
  int result = codec->encoder ? opus_encoder_ctl(codec->encoder, OPUS_RESET_STATE) :
                               opus_decoder_ctl(codec->decoder, OPUS_RESET_STATE);
  enif_mutex_unlock(codec->mutex);
  return result == OPUS_OK ? atom(env, "ok") : opus_error(env, result);
}
static ERL_NIF_TERM close_codec(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Codec *codec;
  if (!enif_get_resource(env, argv[0], codec_type, (void **)&codec)) return enif_make_badarg(env);
  if (enif_mutex_trylock(codec->mutex)) return error(env, "busy");
  destroy(codec);
  enif_mutex_unlock(codec->mutex);
  return atom(env, "ok");
}
static ErlNifFunc functions[] = {
  {"version", 0, version, 0},
  {"new", 4, create, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"configure", 7, configure, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"settings", 1, settings, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"encode", 3, encode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"decode", 4, decode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"packet_info", 2, packet_info, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"reset", 1, reset, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"close", 1, close_codec, ERL_NIF_DIRTY_JOB_CPU_BOUND}
};
ERL_NIF_INIT(Elixir.OpusProbe, functions, load, NULL, NULL, NULL)
