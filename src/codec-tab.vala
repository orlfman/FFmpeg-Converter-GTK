public interface ICodecTab : Object {
    public abstract ICodecBuilder get_codec_builder ();
    public abstract bool get_two_pass ();
    public abstract string get_container ();
    public abstract string[] resolve_keyframe_args (string input_file, GeneralTab general_tab);
    public abstract string[] get_audio_args ();
}
