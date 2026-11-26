// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * audio.primary.kindle.so — Minimal Android 7.1 primary Audio HAL for Kobo Libra 2.
 *
 * Bridges AudioFlinger 44.1 kHz / 16-bit stereo PCM to the Kobo host via
 * /dev/kfb/audio.fifo (consumed by aplay -> BlueALSA when a Bluetooth A2DP
 * headset/speaker is connected).
 *
 * When no Bluetooth audio sink is attached, open(O_WRONLY|O_NONBLOCK) returns
 * ENXIO and out_write() silently paces real-time at zero overhead so apps
 * never block or stall.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Android 7.1 Bionic (ARM32) ABI guards: 32-bit time_t + __errno() */
_Static_assert(sizeof(struct timespec) == 8, "Bionic ARM32 timespec must be 8 bytes");
extern int *__errno(void);
#undef errno
#define errno (*__errno())

#include <hardware/audio.h>
#include <hardware/hardware.h>
#include <system/audio.h>

#define AUDIO_FIFO_PATH   "/dev/kfb/audio.fifo"
#define AUDIO_ACTIVE_PATH "/dev/kfb/audio.active"

#define OUT_SAMPLE_RATE   44100U
#define OUT_CHANNELS      AUDIO_CHANNEL_OUT_STEREO
#define OUT_FORMAT        AUDIO_FORMAT_PCM_16_BIT
#define OUT_FRAME_SIZE    4U      /* 2 ch * 16-bit */
#define OUT_PERIOD_FRAMES 1024U   /* ~23.2 ms per write */
#define OUT_BUFFER_BYTES  (OUT_PERIOD_FRAMES * OUT_FRAME_SIZE)

struct kobo_audio_device {
    struct audio_hw_device dev;
    bool mic_mute;
    audio_mode_t mode;
};

struct kobo_stream_out {
    struct audio_stream_out stream;
    int fifo_fd;
    uint64_t written_frames;
    int64_t last_open_try_ms;
    int64_t last_active_touch_ms;
    int64_t next_pace_us;
};

static int64_t mono_us(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000000LL + (int64_t)(ts.tv_nsec / 1000L);
}

static void touch_active(struct kobo_stream_out *out, int64_t now_ms) {
    if (now_ms - out->last_active_touch_ms < 2500) return;
    out->last_active_touch_ms = now_ms;
    int fd = open(AUDIO_ACTIVE_PATH, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
    if (fd >= 0) {
        (void)write(fd, "1\n", 2);
        close(fd);
    }
}

static void clear_active(void) {
    unlink(AUDIO_ACTIVE_PATH);
}

static void close_fifo(struct kobo_stream_out *out) {
    if (out->fifo_fd >= 0) {
        close(out->fifo_fd);
        out->fifo_fd = -1;
    }
    clear_active();
}

static void try_open_fifo(struct kobo_stream_out *out, int64_t now_ms) {
    if (out->fifo_fd >= 0) return;
    if (now_ms - out->last_open_try_ms < 250) return;
    out->last_open_try_ms = now_ms;
    int fd = open(AUDIO_FIFO_PATH, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) {
        out->fifo_fd = fd;
        out->next_pace_us = 0;
    }
}

/* ---- audio_stream_out methods ---- */

static uint32_t out_get_sample_rate(const struct audio_stream *stream) {
    (void)stream;
    return OUT_SAMPLE_RATE;
}

static int out_set_sample_rate(struct audio_stream *stream, uint32_t rate) {
    (void)stream;
    return rate == OUT_SAMPLE_RATE ? 0 : -EINVAL;
}

static size_t out_get_buffer_size(const struct audio_stream *stream) {
    (void)stream;
    return OUT_BUFFER_BYTES;
}

static audio_channel_mask_t out_get_channels(const struct audio_stream *stream) {
    (void)stream;
    return OUT_CHANNELS;
}

static audio_format_t out_get_format(const struct audio_stream *stream) {
    (void)stream;
    return OUT_FORMAT;
}

static int out_set_format(struct audio_stream *stream, audio_format_t format) {
    (void)stream;
    return format == OUT_FORMAT ? 0 : -EINVAL;
}

static int out_standby(struct audio_stream *stream) {
    struct kobo_stream_out *out = (struct kobo_stream_out *)stream;
    close_fifo(out);
    out->next_pace_us = 0;
    return 0;
}

static int out_dump(const struct audio_stream *stream, int fd) {
    (void)stream;
    (void)fd;
    return 0;
}

static audio_devices_t out_get_device(const struct audio_stream *stream) {
    (void)stream;
    return AUDIO_DEVICE_OUT_SPEAKER;
}

static int out_set_device(struct audio_stream *stream, audio_devices_t device) {
    (void)stream;
    (void)device;
    return 0;
}

static int out_set_parameters(struct audio_stream *stream, const char *kv_pairs) {
    (void)stream;
    (void)kv_pairs;
    return 0;
}

static char *out_get_parameters(const struct audio_stream *stream, const char *keys) {
    (void)stream;
    (void)keys;
    return strdup("");
}

static uint32_t out_get_latency(const struct audio_stream_out *stream) {
    (void)stream;
    return 80;
}

static int out_set_volume(struct audio_stream_out *stream, float left, float right) {
    (void)stream;
    (void)left;
    (void)right;
    return -ENOSYS; /* Let AudioFlinger software mixer apply volume smoothly */
}

static ssize_t out_write(struct audio_stream_out *stream, const void *buffer, size_t bytes) {
    struct kobo_stream_out *out = (struct kobo_stream_out *)stream;
    int64_t now_us = mono_us();
    int64_t now_ms = now_us / 1000LL;
    size_t frames = bytes / OUT_FRAME_SIZE;
    int64_t dur_us = (int64_t)frames * 1000000LL / (int64_t)OUT_SAMPLE_RATE;

    try_open_fifo(out, now_ms);

    if (out->fifo_fd >= 0) {
        const uint8_t *p = (const uint8_t *)buffer;
        size_t left = bytes;
        int64_t deadline_us = now_us + (dur_us > 20000 ? dur_us * 3 : 60000);

        while (left > 0) {
            struct pollfd pfd;
            pfd.fd = out->fifo_fd;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            int pr = poll(&pfd, 1, 20);
            if (pr < 0) {
                if (errno == EINTR) continue;
                close_fifo(out);
                break;
            }
            if (pr == 0) {
                if (mono_us() >= deadline_us) break;
                continue;
            }
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                close_fifo(out);
                break;
            }
            ssize_t w = write(out->fifo_fd, p, left);
            if (w > 0) {
                p += (size_t)w;
                left -= (size_t)w;
            } else if (w < 0 && (errno == EAGAIN || errno == EINTR)) {
                if (mono_us() >= deadline_us) break;
                usleep(2000);
            } else {
                close_fifo(out);
                break;
            }
        }
        if (out->fifo_fd >= 0) {
            touch_active(out, now_ms);
            out->written_frames += frames;
            return (ssize_t)bytes;
        }
    }

    /* Silent fallback pacing when no BT audio sink is active */
    if (out->next_pace_us == 0 || now_us - out->next_pace_us > 100000) {
        out->next_pace_us = now_us + dur_us;
    } else {
        out->next_pace_us += dur_us;
    }
    int64_t wait_us = out->next_pace_us - now_us;
    if (wait_us > 500 && wait_us < 100000) {
        usleep((useconds_t)wait_us);
    }
    out->written_frames += frames;
    return (ssize_t)bytes;
}

static int out_get_render_position(const struct audio_stream_out *stream, uint32_t *dsp_frames) {
    const struct kobo_stream_out *out = (const struct kobo_stream_out *)stream;
    if (!dsp_frames) return -EINVAL;
    *dsp_frames = (uint32_t)out->written_frames;
    return 0;
}

static int out_get_presentation_position(const struct audio_stream_out *stream,
                                         uint64_t *frames, struct timespec *timestamp) {
    const struct kobo_stream_out *out = (const struct kobo_stream_out *)stream;
    if (!frames || !timestamp) return -EINVAL;
    *frames = out->written_frames;
    clock_gettime(CLOCK_MONOTONIC, timestamp);
    return 0;
}

static int out_add_audio_effect(const struct audio_stream *stream, effect_handle_t effect) {
    (void)stream;
    (void)effect;
    return 0;
}

static int out_remove_audio_effect(const struct audio_stream *stream, effect_handle_t effect) {
    (void)stream;
    (void)effect;
    return 0;
}

static int out_get_next_write_timestamp(const struct audio_stream_out *stream, int64_t *timestamp) {
    (void)stream;
    (void)timestamp;
    return -ENOSYS;
}

/* ---- audio_hw_device methods ---- */

static int adev_open_output_stream(struct audio_hw_device *dev,
                                   audio_io_handle_t handle,
                                   audio_devices_t devices,
                                   audio_output_flags_t flags,
                                   struct audio_config *config,
                                   struct audio_stream_out **stream_out,
                                   const char *address) {
    (void)dev;
    (void)handle;
    (void)devices;
    (void)flags;
    (void)address;

    struct kobo_stream_out *out = (struct kobo_stream_out *)calloc(1, sizeof(*out));
    if (!out) return -ENOMEM;

    out->fifo_fd = -1;
    out->stream.common.get_sample_rate = out_get_sample_rate;
    out->stream.common.set_sample_rate = out_set_sample_rate;
    out->stream.common.get_buffer_size = out_get_buffer_size;
    out->stream.common.get_channels = out_get_channels;
    out->stream.common.get_format = out_get_format;
    out->stream.common.set_format = out_set_format;
    out->stream.common.standby = out_standby;
    out->stream.common.dump = out_dump;
    out->stream.common.get_device = out_get_device;
    out->stream.common.set_device = out_set_device;
    out->stream.common.set_parameters = out_set_parameters;
    out->stream.common.get_parameters = out_get_parameters;
    out->stream.common.add_audio_effect = out_add_audio_effect;
    out->stream.common.remove_audio_effect = out_remove_audio_effect;

    out->stream.get_latency = out_get_latency;
    out->stream.set_volume = out_set_volume;
    out->stream.write = out_write;
    out->stream.get_render_position = out_get_render_position;
    out->stream.get_next_write_timestamp = out_get_next_write_timestamp;
    out->stream.get_presentation_position = out_get_presentation_position;

    if (config) {
        config->sample_rate = OUT_SAMPLE_RATE;
        config->channel_mask = OUT_CHANNELS;
        config->format = OUT_FORMAT;
    }

    *stream_out = &out->stream;
    return 0;
}

static void adev_close_output_stream(struct audio_hw_device *dev, struct audio_stream_out *stream) {
    (void)dev;
    if (!stream) return;
    struct kobo_stream_out *out = (struct kobo_stream_out *)stream;
    close_fifo(out);
    free(out);
}

static int adev_set_parameters(struct audio_hw_device *dev, const char *kv_pairs) {
    (void)dev;
    (void)kv_pairs;
    return 0;
}

static char *adev_get_parameters(const struct audio_hw_device *dev, const char *keys) {
    (void)dev;
    (void)keys;
    return strdup("");
}

static int adev_init_check(const struct audio_hw_device *dev) {
    (void)dev;
    return 0;
}

static int adev_set_voice_volume(struct audio_hw_device *dev, float volume) {
    (void)dev;
    (void)volume;
    return 0;
}

static int adev_set_master_volume(struct audio_hw_device *dev, float volume) {
    (void)dev;
    (void)volume;
    return -ENOSYS;
}

static int adev_set_mode(struct audio_hw_device *dev, audio_mode_t mode) {
    struct kobo_audio_device *adev = (struct kobo_audio_device *)dev;
    adev->mode = mode;
    return 0;
}

static int adev_set_mic_mute(struct audio_hw_device *dev, bool state) {
    struct kobo_audio_device *adev = (struct kobo_audio_device *)dev;
    adev->mic_mute = state;
    return 0;
}

static int adev_get_mic_mute(const struct audio_hw_device *dev, bool *state) {
    const struct kobo_audio_device *adev = (const struct kobo_audio_device *)dev;
    if (state) *state = adev->mic_mute;
    return 0;
}

static size_t adev_get_input_buffer_size(const struct audio_hw_device *dev,
                                         const struct audio_config *config) {
    (void)dev;
    (void)config;
    return 0;
}

static int adev_open_input_stream(struct audio_hw_device *dev,
                                  audio_io_handle_t handle,
                                  audio_devices_t devices,
                                  struct audio_config *config,
                                  struct audio_stream_in **stream_in,
                                  audio_input_flags_t flags,
                                  const char *address,
                                  audio_source_t source) {
    (void)dev; (void)handle; (void)devices; (void)config;
    (void)stream_in; (void)flags; (void)address; (void)source;
    return -ENOSYS;
}

static void adev_close_input_stream(struct audio_hw_device *dev, struct audio_stream_in *in) {
    (void)dev;
    (void)in;
}

static int adev_dump(const struct audio_hw_device *dev, int fd) {
    (void)dev;
    (void)fd;
    return 0;
}

static int adev_close(hw_device_t *device) {
    free(device);
    return 0;
}

static int adev_open(const hw_module_t *module, const char *name, hw_device_t **device) {
    if (strcmp(name, AUDIO_HARDWARE_INTERFACE) != 0) return -EINVAL;

    struct kobo_audio_device *adev = (struct kobo_audio_device *)calloc(1, sizeof(*adev));
    if (!adev) return -ENOMEM;

    adev->dev.common.tag = HARDWARE_DEVICE_TAG;
    adev->dev.common.version = AUDIO_DEVICE_API_VERSION_2_0;
    adev->dev.common.module = (struct hw_module_t *)module;
    adev->dev.common.close = adev_close;

    adev->dev.init_check = adev_init_check;
    adev->dev.set_voice_volume = adev_set_voice_volume;
    adev->dev.set_master_volume = adev_set_master_volume;
    adev->dev.set_mode = adev_set_mode;
    adev->dev.set_mic_mute = adev_set_mic_mute;
    adev->dev.get_mic_mute = adev_get_mic_mute;
    adev->dev.set_parameters = adev_set_parameters;
    adev->dev.get_parameters = adev_get_parameters;
    adev->dev.get_input_buffer_size = adev_get_input_buffer_size;
    adev->dev.open_output_stream = adev_open_output_stream;
    adev->dev.close_output_stream = adev_close_output_stream;
    adev->dev.open_input_stream = adev_open_input_stream;
    adev->dev.close_input_stream = adev_close_input_stream;
    adev->dev.dump = adev_dump;

    *device = &adev->dev.common;
    return 0;
}

static struct hw_module_methods_t hal_module_methods = {
    .open = adev_open,
};

struct audio_module HAL_MODULE_INFO_SYM = {
    .common = {
        .tag = HARDWARE_MODULE_TAG,
        .module_api_version = AUDIO_MODULE_API_VERSION_0_1,
        .hal_api_version = HARDWARE_HAL_API_VERSION,
        .id = AUDIO_HARDWARE_MODULE_ID,
        .name = "Kobo Libra 2 BlueALSA Audio HAL",
        .author = "Veradroid-Libra2",
        .methods = &hal_module_methods,
    },
};
