public interface ICodecBuilder : Object {
    public abstract string get_codec_name ();
    public abstract Object? snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null);
    public abstract string[] build_codec_args_from_snapshot (
        Object? snapshot);
    public abstract string[] get_codec_args ();
}
