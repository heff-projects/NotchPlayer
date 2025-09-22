#include "ffdecode.h"
#include <stdlib.h>
#include <limits.h>
#include <CoreVideo/CoreVideo.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>



// ffdecode.c
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

// Best-effort, fast duration probe without decoding frames.
double ff_probe_duration(const char *path) {
    AVFormatContext *fmt = NULL;
    double dur = NAN;

    if (avformat_open_input(&fmt, path, NULL, NULL) != 0) return NAN;
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        avformat_close_input(&fmt);
        return NAN;
    }

    // 1) Container duration
    if (fmt->duration > 0) {
        dur = (double)fmt->duration / (double)AV_TIME_BASE;
    }

    // Find best video stream (for stream-based fallbacks)
    int vindex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    AVStream *vs = (vindex >= 0) ? fmt->streams[vindex] : NULL;

    // 2) Stream duration in stream time_base
    if (!(dur > 0) && vs && vs->duration > 0) {
        AVRational tb = vs->time_base;
        dur = (double)vs->duration * av_q2d(tb);
    }

    // 3) nb_frames / avg_frame_rate
    if (!(dur > 0) && vs && vs->nb_frames > 0) {
        AVRational afr = vs->avg_frame_rate.num > 0 ? vs->avg_frame_rate : vs->r_frame_rate;
        double fps = (afr.den > 0) ? (double)afr.num / (double)afr.den : 0.0;
        if (fps > 0.0) dur = (double)vs->nb_frames / fps;
    }

    // 4) file size / bit_rate (very rough, but better than nothing)
    if (!(dur > 0) && fmt->bit_rate > 0 && fmt->pb) {
        int64_t size = avio_size(fmt->pb);
        if (size > 0) dur = (double)(size * 8) / (double)fmt->bit_rate;
    }

    avformat_close_input(&fmt);
    return (dur > 0) ? dur : NAN;
}
double ff_frame_accurate_duration(const char* path) {
    if (!path) return NAN;

    AVFormatContext *fmt = NULL;
    double out = NAN;

    if (avformat_open_input(&fmt, path, NULL, NULL) != 0) return NAN;
    if (avformat_find_stream_info(fmt, NULL) < 0) { avformat_close_input(&fmt); return NAN; }

    int vindex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vindex >= 0) {
        AVStream *vs = fmt->streams[vindex];

        // Prefer avg_frame_rate; if missing, try r_frame_rate
        AVRational afr = vs->avg_frame_rate.num > 0 ? vs->avg_frame_rate : vs->r_frame_rate;
        if (afr.num > 0 && afr.den > 0 && vs->nb_frames > 0) {
            // nb_frames is integer count of frames; afr is exact (e.g., 30000/1001)
            out = (double)vs->nb_frames * ((double)afr.den / (double)afr.num);
        } else if (vs->duration != AV_NOPTS_VALUE) {
            // Fallback: stream duration_ts * time_base
            out = (double)vs->duration * av_q2d(vs->time_base);
        }
    }

    avformat_close_input(&fmt);
    return (out > 0) ? out : NAN;
}


double ff_get_avg_fps(const char* path) {
    if (!path) return NAN;
    AVFormatContext *fmt = NULL;
    double fps = NAN;

    if (avformat_open_input(&fmt, path, NULL, NULL) != 0) return NAN;
    if (avformat_find_stream_info(fmt, NULL) < 0) { avformat_close_input(&fmt); return NAN; }

    int vindex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vindex >= 0) {
        AVStream *vs = fmt->streams[vindex];
        AVRational afr = (vs->avg_frame_rate.num > 0) ? vs->avg_frame_rate : vs->r_frame_rate;
        if (afr.num > 0 && afr.den > 0) fps = (double)afr.num / (double)afr.den;
    }

    avformat_close_input(&fmt);
    return fps;
}
int ff_is_notchlc(const char* path) {
    if (!path) return -1;

    AVFormatContext *fmt = NULL;
    int ret = -1;

    if (avformat_open_input(&fmt, path, NULL, NULL) != 0) return -1;
    if (avformat_find_stream_info(fmt, NULL) < 0) { avformat_close_input(&fmt); return -1; }

    int vindex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vindex < 0) { avformat_close_input(&fmt); return -1; }

    AVStream *vs = fmt->streams[vindex];
    enum AVCodecID cid = vs->codecpar->codec_id;

    // Prefer codec_id, fall back to codec tag/name if needed
    int is_notch = 0;

    // 1) codec_id name equals "notchlc"?
    const char* name = avcodec_get_name(cid);
    if (name && strcmp(name, "notchlc") == 0) {
        is_notch = 1;
    } else {
        // 2) some builds tag NotchLC as 'nclc' in MOV
        unsigned int tag = vs->codecpar->codec_tag; // e.g. 'nclc'
        if (tag) {
            char tagstr[5] = {0};
            tagstr[0] = (char)( tag        & 0xFF);
            tagstr[1] = (char)((tag >> 8 ) & 0xFF);
            tagstr[2] = (char)((tag >> 16) & 0xFF);
            tagstr[3] = (char)((tag >> 24) & 0xFF);
            if (strcmp(tagstr, "nclc") == 0) is_notch = 1;
        }
    }

    avformat_close_input(&fmt);
    ret = is_notch ? 1 : 0;
    return ret;
}
double ff_format_duration(const char* path) {
    if (!path) return NAN;
    AVFormatContext *fmt = NULL;
    double dur = NAN;

    if (avformat_open_input(&fmt, path, NULL, NULL) != 0) return NAN;
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        avformat_close_input(&fmt);
        return NAN;
    }

    if (fmt->duration > 0) {
        dur = (double)fmt->duration / (double)AV_TIME_BASE;
    }

    avformat_close_input(&fmt);
    return (dur > 0) ? dur : NAN;
}

static int try_seek_to_end(AVFormatContext *fmt, int vindex) {
    // First try: generic "as far as possible" with BACKWARD flag
    if (avformat_seek_file(fmt, vindex, INT64_MIN, INT64_MAX, INT64_MAX, AVSEEK_FLAG_BACKWARD) >= 0) {
        return 0;
    }

    AVStream *vs = fmt->streams[vindex];

    // Second try: use container duration (microseconds) converted to stream time_base
    if (fmt->duration > 0) {
        int64_t ts = av_rescale_q(fmt->duration - 1, AV_TIME_BASE_Q, vs->time_base);
        if (av_seek_frame(fmt, vindex, ts, AVSEEK_FLAG_BACKWARD) >= 0) {
            return 0;
        }
    }

    // Third try: use stream duration if available
    if (vs->duration != AV_NOPTS_VALUE && vs->duration > 0) {
        int64_t ts = vs->duration - 1;
        if (av_seek_frame(fmt, vindex, ts, AVSEEK_FLAG_BACKWARD) >= 0) {
            return 0;
        }
    }

    // Last resort: seek to zero (we'll still scan forward; better than failing)
    if (av_seek_frame(fmt, vindex, 0, AVSEEK_FLAG_BACKWARD) >= 0) {
        return 0;
    }

    return -1;
}

double ff_precise_duration(const char* path) {
    if (!path) return NAN;

    AVFormatContext *fmt = NULL;
    double result = NAN;

    if (avformat_open_input(&fmt, path, NULL, NULL) != 0) return NAN;
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        avformat_close_input(&fmt);
        return NAN;
    }

    int vindex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vindex < 0) {
        // No video stream — fall back to container duration
        if (fmt->duration > 0) result = (double)fmt->duration / (double)AV_TIME_BASE;
        avformat_close_input(&fmt);
        return (result > 0) ? result : NAN;
    }

    AVStream *vs = fmt->streams[vindex];
    AVRational tb = vs->time_base;

    // Try a few windows near EOF in case the file has sparse trailing packets
    const double windows_sec[] = { 0.0, 5.0, 30.0 };
    int64_t last_ts = AV_NOPTS_VALUE;

    for (int w = 0; w < (int)(sizeof(windows_sec)/sizeof(windows_sec[0])); ++w) {
        // Seek near end
        if (try_seek_to_end(fmt, vindex) < 0) break;

        // If we want to start a bit earlier than exact EOF, step back by window size
        if (windows_sec[w] > 0.0) {
            int64_t step = (int64_t)(windows_sec[w] / av_q2d(tb));
            int64_t target = INT64_MAX; // we just sought to end, so use a big number then step back
            if (fmt->duration > 0) {
                target = av_rescale_q(fmt->duration, AV_TIME_BASE_Q, tb);
            } else if (vs->duration != AV_NOPTS_VALUE) {
                target = vs->duration;
            }
            if (target != INT64_MAX) {
                int64_t back = target - (step > 0 ? step : 1);
                if (back < 0) back = 0;
                av_seek_frame(fmt, vindex, back, AVSEEK_FLAG_BACKWARD);
            }
        }

        // Read forward; grab the last video packet timestamp we see.
        AVPacket *pkt = av_packet_alloc();
        if (!pkt) break;

        int iter = 0;
        while (iter++ < 10000) { // hard cap to avoid infinite loops on broken files
            int r = av_read_frame(fmt, pkt);
            if (r < 0) break;
            if (pkt->stream_index == vindex) {
                int64_t ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts :
                             (pkt->dts != AV_NOPTS_VALUE) ? pkt->dts : AV_NOPTS_VALUE;
                if (ts != AV_NOPTS_VALUE) last_ts = ts;
            }
            av_packet_unref(pkt);
        }
        av_packet_free(&pkt);

        if (last_ts != AV_NOPTS_VALUE) break; // found something
    }

    if (last_ts != AV_NOPTS_VALUE) {
        result = last_ts * av_q2d(tb);
    } else if (vs->duration != AV_NOPTS_VALUE && vs->duration > 0) {
        result = vs->duration * av_q2d(tb);
    } else if (fmt->duration > 0) {
        result = (double)fmt->duration / (double)AV_TIME_BASE;
    }

    avformat_close_input(&fmt);
    return (result > 0) ? result : NAN;
}

struct FFPlayer {
    AVFormatContext* fmt;
    AVCodecContext*  vdec;
    int              vstream;
    AVFrame*         frame;
    AVPacket*        pkt;
    struct SwsContext* sws;
    int out_w, out_h;
    int at_eof;   // track EOF state
};

static int setup_sws(FFPlayer* p) {
    if (p->sws) return 0;
    p->sws = sws_getContext(p->vdec->width, p->vdec->height, p->vdec->pix_fmt,
                            p->vdec->width, p->vdec->height, AV_PIX_FMT_BGRA,
                            SWS_BILINEAR, NULL, NULL, NULL);
    return p->sws ? 0 : -1;
}

FFPlayer* ff_open(const char* path, int* width, int* height, double* time_base, double* duration_s) {
    av_log_set_level(AV_LOG_ERROR);

    FFPlayer* p = calloc(1, sizeof(*p));
    if (!p) return NULL;

    if (avformat_open_input(&p->fmt, path, NULL, NULL) < 0) goto fail;
    if (avformat_find_stream_info(p->fmt, NULL) < 0) goto fail;

    p->vstream = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (p->vstream < 0) goto fail;

    AVStream* vs = p->fmt->streams[p->vstream];
    const AVCodec* dec = avcodec_find_decoder(vs->codecpar->codec_id);
    if (!dec) goto fail;

    p->vdec = avcodec_alloc_context3(dec);
    if (!p->vdec) goto fail;
    if (avcodec_parameters_to_context(p->vdec, vs->codecpar) < 0) goto fail;
    if (avcodec_open2(p->vdec, dec, NULL) < 0) goto fail;

    p->frame = av_frame_alloc();
    p->pkt   = av_packet_alloc();
    if (!p->frame || !p->pkt) goto fail;

    p->out_w = p->vdec->width;
    p->out_h = p->vdec->height;
    p->at_eof = 0;

    if (width)  *width  = p->out_w;
    if (height) *height = p->out_h;

    if (time_base) *time_base = av_q2d(vs->time_base);

    if (duration_s) {
        double dur = NAN;
        if (p->fmt->duration != AV_NOPTS_VALUE) {
            dur = (double)p->fmt->duration / AV_TIME_BASE;
        } else if (vs->duration != AV_NOPTS_VALUE) {
            dur = vs->duration * av_q2d(vs->time_base);
        }
        *duration_s = dur; // may be NaN if unknown
    }

    return p;
fail:
    if (p) {
        if (p->frame) av_frame_free(&p->frame);
        if (p->pkt) av_packet_free(&p->pkt);
        if (p->vdec) avcodec_free_context(&p->vdec);
        if (p->fmt) avformat_close_input(&p->fmt);
        free(p);
    }
    return NULL;
}


void ff_close(FFPlayer* p) {
    if (!p) return;
    if (p->sws) sws_freeContext(p->sws);
    if (p->frame) av_frame_free(&p->frame);
    if (p->pkt) av_packet_free(&p->pkt);
    if (p->vdec) avcodec_free_context(&p->vdec);
    if (p->fmt) avformat_close_input(&p->fmt);
    free(p);
}

int ff_next_frame(FFPlayer* p, CVImageBufferRef* out_ib, double* out_pts_s) {
    *out_ib = NULL;
    if (!p->sws && setup_sws(p) < 0) return -2;

    for (;;) {
        int r;

        if (!p->at_eof) {
            r = av_read_frame(p->fmt, p->pkt);
            if (r == AVERROR_EOF) {
                // No more packets → start draining
                p->at_eof = 1;
                av_packet_unref(p->pkt);
                avcodec_send_packet(p->vdec, NULL);
            } else if (r < 0) {
                // Read error (not EOF)
                av_packet_unref(p->pkt);
                return r;
            } else if (p->pkt->stream_index != p->vstream) {
                av_packet_unref(p->pkt);
                continue;
            } else {
                // Normal packet
                r = avcodec_send_packet(p->vdec, p->pkt);
                av_packet_unref(p->pkt);
                
            }
        } else {
            // Already at EOF → keep draining
            r = avcodec_send_packet(p->vdec, NULL);
            if (r < 0 && r != AVERROR(EAGAIN)) {
                return r;
            }
        }

        // Try to receive a frame
        r = avcodec_receive_frame(p->vdec, p->frame);
        if (r == AVERROR(EAGAIN)) {
            continue; // need more input
        }
        if (r == AVERROR_EOF) {
            // Fully drained → normalize to 0
            return 0;
        }
        if (r < 0) {
            return r; // real decode error
        }

        // Convert to CVPixelBuffer
        CVPixelBufferRef pb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault,
                                p->out_w, p->out_h,
                                kCVPixelFormatType_32BGRA,
                                NULL, &pb) != kCVReturnSuccess) {
            return -3;
        }

        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t* dst = (uint8_t*)CVPixelBufferGetBaseAddress(pb);
        size_t dst_stride = CVPixelBufferGetBytesPerRow(pb);

        uint8_t* planes[4] = { dst, NULL, NULL, NULL };
        int      strides[4]= { (int)dst_stride, 0, 0, 0 };

        sws_scale(p->sws,
                  (const uint8_t* const*)p->frame->data,
                  p->frame->linesize,
                  0, p->vdec->height,
                  planes, strides);

        CVPixelBufferUnlockBaseAddress(pb, 0);

        double pts = NAN;
        if (p->frame->best_effort_timestamp != AV_NOPTS_VALUE) {
            AVRational tb = p->fmt->streams[p->vstream]->time_base;
            pts = p->frame->best_effort_timestamp * av_q2d(tb);
        }

        *out_ib = (CVImageBufferRef)pb;   // retained buffer
        if (out_pts_s) *out_pts_s = pts;

        av_frame_unref(p->frame);
        return 1;
    }
}

