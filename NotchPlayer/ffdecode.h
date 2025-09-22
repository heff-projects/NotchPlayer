#pragma once
typedef struct __CVBuffer *CVImageBufferRef;

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FFPlayer FFPlayer;

// Returns average frame rate (fps), or NaN if unknown.
double ff_get_avg_fps(const char* path);

// Returns nb_frames / avg_frame_rate (or r_frame_rate) in seconds, if available.
// Falls back to stream duration_ts*time_base, else NaN.
double ff_frame_accurate_duration(const char* path);

// Returns 1 if the best video stream is NotchLC, 0 if not, -1 on error.
int ff_is_notchlc(const char* path);

// Returns a precise stream duration (seconds) by seeking near the end and scanning
// last video packet timestamps, or NaN if unknown.
double ff_precise_duration(const char* path);

// Returns container (FORMAT) duration in seconds, like ffprobe's [FORMAT] duration.
// Returns NaN if unknown.
double ff_format_duration(const char* path);

// NOTE the 5th parameter: duration_s
FFPlayer* ff_open(const char* path, int* width, int* height, double* time_base, double* duration_s);
void      ff_close(FFPlayer* p);
int       ff_next_frame(FFPlayer* p, CVImageBufferRef* out_ib, double* out_pts_s);

#ifdef __cplusplus
}
#endif
