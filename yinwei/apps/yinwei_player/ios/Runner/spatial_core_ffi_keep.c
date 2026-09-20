/* Linker roots for the Rust spatial_core C ABI.
 *
 * Dart resolves these names with DynamicLibrary.process() / dlsym. Nothing in
 * the Swift/ObjC Runner calls them, so Apple -dead_strip would otherwise drop
 * the objects pulled from libspatial_core. This file is compiled into the
 * Runner target only (not the App Clip). Do not change FFI signatures here.
 */
#if defined(__GNUC__)
#define YINWEI_USED __attribute__((used))
#else
#define YINWEI_USED
#endif

#define YINWEI_KEEP(sym) extern void sym(void)

YINWEI_KEEP(yinwei_last_error);
YINWEI_KEEP(yinwei_open);
YINWEI_KEEP(yinwei_track_title);
YINWEI_KEEP(yinwei_track_artist);
YINWEI_KEEP(yinwei_track_album);
YINWEI_KEEP(yinwei_track_path);
YINWEI_KEEP(yinwei_track_duration_ms);
YINWEI_KEEP(yinwei_track_sample_rate);
YINWEI_KEEP(yinwei_set_params);
YINWEI_KEEP(yinwei_get_params);
YINWEI_KEEP(yinwei_set_eq);
YINWEI_KEEP(yinwei_set_array);
YINWEI_KEEP(yinwei_set_speaker);
YINWEI_KEEP(yinwei_set_speaker_count);
YINWEI_KEEP(yinwei_apply_preset);
YINWEI_KEEP(yinwei_set_mode);
YINWEI_KEEP(yinwei_rebuild_preview);
YINWEI_KEEP(yinwei_play);
YINWEI_KEEP(yinwei_pause);
YINWEI_KEEP(yinwei_seek_ms);
YINWEI_KEEP(yinwei_position_ms);
YINWEI_KEEP(yinwei_is_playing);
YINWEI_KEEP(yinwei_current_azimuth_deg);
YINWEI_KEEP(yinwei_current_elevation_deg);
YINWEI_KEEP(yinwei_export_wav);
YINWEI_KEEP(yinwei_dispose);
YINWEI_KEEP(yinwei_is_preview_dirty);
YINWEI_KEEP(yinwei_live_start);
YINWEI_KEEP(yinwei_live_stop);
YINWEI_KEEP(yinwei_live_is_running);
YINWEI_KEEP(yinwei_live_set_mode);
YINWEI_KEEP(yinwei_live_azimuth_deg);
YINWEI_KEEP(yinwei_live_elevation_deg);
YINWEI_KEEP(yinwei_live_captured_frames);
YINWEI_KEEP(yinwei_live_set_params);
YINWEI_KEEP(yinwei_live_set_eq);
YINWEI_KEEP(yinwei_live_set_array);
YINWEI_KEEP(yinwei_live_set_speaker);
YINWEI_KEEP(yinwei_live_set_speaker_count);
YINWEI_KEEP(yinwei_live_energy_frames);
YINWEI_KEEP(yinwei_live_last_energy_ms);
YINWEI_KEEP(yinwei_live_list_output_devices);
YINWEI_KEEP(yinwei_live_set_output_device);
YINWEI_KEEP(yinwei_live_output_device);
YINWEI_KEEP(yinwei_live_set_output_hold);

#undef YINWEI_KEEP

YINWEI_USED const void *const kYinweiFfiKeep[] = {
    (const void *)yinwei_last_error,
    (const void *)yinwei_open,
    (const void *)yinwei_track_title,
    (const void *)yinwei_track_artist,
    (const void *)yinwei_track_album,
    (const void *)yinwei_track_path,
    (const void *)yinwei_track_duration_ms,
    (const void *)yinwei_track_sample_rate,
    (const void *)yinwei_set_params,
    (const void *)yinwei_get_params,
    (const void *)yinwei_set_eq,
    (const void *)yinwei_set_array,
    (const void *)yinwei_set_speaker,
    (const void *)yinwei_set_speaker_count,
    (const void *)yinwei_apply_preset,
    (const void *)yinwei_set_mode,
    (const void *)yinwei_rebuild_preview,
    (const void *)yinwei_play,
    (const void *)yinwei_pause,
    (const void *)yinwei_seek_ms,
    (const void *)yinwei_position_ms,
    (const void *)yinwei_is_playing,
    (const void *)yinwei_current_azimuth_deg,
    (const void *)yinwei_current_elevation_deg,
    (const void *)yinwei_export_wav,
    (const void *)yinwei_dispose,
    (const void *)yinwei_is_preview_dirty,
    (const void *)yinwei_live_start,
    (const void *)yinwei_live_stop,
    (const void *)yinwei_live_is_running,
    (const void *)yinwei_live_set_mode,
    (const void *)yinwei_live_azimuth_deg,
    (const void *)yinwei_live_elevation_deg,
    (const void *)yinwei_live_captured_frames,
    (const void *)yinwei_live_set_params,
    (const void *)yinwei_live_set_eq,
    (const void *)yinwei_live_set_array,
    (const void *)yinwei_live_set_speaker,
    (const void *)yinwei_live_set_speaker_count,
    (const void *)yinwei_live_energy_frames,
    (const void *)yinwei_live_last_energy_ms,
    (const void *)yinwei_live_list_output_devices,
    (const void *)yinwei_live_set_output_device,
    (const void *)yinwei_live_output_device,
    (const void *)yinwei_live_set_output_hold,
};
