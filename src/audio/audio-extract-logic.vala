namespace AudioExtractLogic {

    public bool should_export_separate (int segment_count, bool separate_requested) {
        return segment_count >= 2 && separate_requested;
    }

    public AudioExtractConfig build_snapshot_config (bool copy_mode,
                                                     int segment_count,
                                                     bool separate_requested,
                                                     int source_audio_index,
                                                     int source_channels,
                                                     AudioSettingsSnapshot? audio_settings,
                                                     AudioProcessingSettingsSnapshot processing_settings,
                                                     bool strip_metadata) {
        var config = new AudioExtractConfig ();
        config.copy_mode = copy_mode;
        config.export_separate = should_export_separate (segment_count, separate_requested);
        config.source_audio_index = source_audio_index;
        config.source_channels = source_channels;

        if (!copy_mode && audio_settings != null) {
            config.audio_settings = audio_settings.copy ();
            config.processing = processing_settings.copy ();
        }

        config.strip_metadata = strip_metadata;
        return config;
    }

    public string build_extract_all_summary (int completed_count, int total_count) {
        int failed_count = total_count - completed_count;
        if (failed_count < 0) {
            failed_count = 0;
        }

        string summary = "Extracted %d of %d audio track%s".printf (
            completed_count,
            total_count,
            total_count == 1 ? "" : "s"
        );

        if (failed_count > 0) {
            summary += " (%d failed)".printf (failed_count);
        }

        return summary;
    }
}
