public interface ICodecBuilder : Object {
    public abstract string get_codec_name ();
    public abstract string[] get_codec_args (Object codec_tab);
}
