using GLib;

namespace SubtitleLanguageGuesser {
    private enum TokenKind {
        LANGUAGE,
        AMBIGUOUS_LANGUAGE,
        REGION,
        SUBTITLE_TAG,
        BLOCKED_CODE,
        UNKNOWN
    }

    private HashTable<string, bool>? known_language_codes = null;
    private HashTable<string, bool>? fallback_language_codes = null;
    private HashTable<string, bool>? known_region_codes = null;
    private HashTable<string, bool>? fallback_region_codes = null;

    public string guess_from_path (string path) {
        return guess_from_path_internal (path, false, false);
    }

#if SUBTITLE_LANGUAGE_GUESSER_TEST_BUILD
    internal string guess_from_path_for_tests (string path,
                                               bool force_language_fallback,
                                               bool force_region_fallback) {
        return guess_from_path_internal (path, force_language_fallback, force_region_fallback);
    }
#endif

    private string guess_from_path_internal (string path,
                                            bool force_language_fallback,
                                            bool force_region_fallback) {
        string bn = Path.get_basename (path);
        int dot = bn.last_index_of_char ('.');
        if (dot <= 0)
            return "und";

        string stem = bn.substring (0, dot);
        string? locale_guess = guess_language_from_locale_suffix (
            stem, force_language_fallback, force_region_fallback);
        if (locale_guess != null)
            return locale_guess;

        string[] tokens = split_language_guess_tokens (stem);
        if (tokens.length == 0)
            return "und";

        string? guessed = guess_language_from_tokens (
            tokens, force_language_fallback, force_region_fallback);
        return guessed ?? "und";
    }

    private string? guess_language_from_tokens (string[] tokens,
                                                bool force_language_fallback,
                                                bool force_region_fallback) {
        int last_index = tokens.length - 1;
        string last_raw = tokens[last_index];
        string last = normalize_language_guess_token (last_raw);

        switch (classify_token (
            last_raw, last, force_language_fallback, force_region_fallback)) {
            case TokenKind.LANGUAGE:
                return last;
            case TokenKind.AMBIGUOUS_LANGUAGE:
                string? previous_language = find_previous_language_token (
                    tokens, last_index - 1, force_language_fallback, force_region_fallback);
                if (previous_language != null)
                    return previous_language;
                return last;
            case TokenKind.SUBTITLE_TAG:
            case TokenKind.BLOCKED_CODE:
            case TokenKind.REGION:
            case TokenKind.UNKNOWN:
            default:
                return find_previous_language_token (
                    tokens, last_index - 1, force_language_fallback, force_region_fallback);
        }
    }

    private string? guess_language_from_locale_suffix (string stem,
                                                       bool force_language_fallback,
                                                       bool force_region_fallback) {
        int region_sep = int.max (stem.last_index_of_char ('-'), stem.last_index_of_char ('_'));
        if (region_sep <= 0 || region_sep >= stem.length - 1)
            return null;

        string region = normalize_language_guess_token (stem.substring (region_sep + 1));
        if (!is_known_region_code (region, force_region_fallback))
            return null;

        string prefix = stem.substring (0, region_sep);
        int language_sep = int.max (
            prefix.last_index_of_char ('.'),
            int.max (prefix.last_index_of_char ('_'), prefix.last_index_of_char ('-'))
        );

        string language = normalize_language_guess_token (
            language_sep >= 0 ? prefix.substring (language_sep + 1) : prefix);
        if (language.length != 2 || !is_known_language_code (language, force_language_fallback))
            return null;

        return language;
    }

    private string? find_previous_language_token (string[] tokens,
                                                  int start_index,
                                                  bool force_language_fallback,
                                                  bool force_region_fallback) {
        for (int i = start_index; i >= 0; i--) {
            string raw = tokens[i];
            string normalized = normalize_language_guess_token (raw);
            if (normalized.length == 0)
                continue;

            switch (classify_token (
                raw, normalized, force_language_fallback, force_region_fallback)) {
                case TokenKind.LANGUAGE:
                case TokenKind.AMBIGUOUS_LANGUAGE:
                    return normalized;
                case TokenKind.REGION:
                case TokenKind.SUBTITLE_TAG:
                case TokenKind.BLOCKED_CODE:
                    continue;
                case TokenKind.UNKNOWN:
                default:
                    break;
            }

            break;
        }

        return null;
    }

    private string[] split_language_guess_tokens (string stem) {
        string[] tokens = {};
        int token_start = 0;

        for (int i = 0; i <= stem.length; i++) {
            bool at_end = (i == stem.length);
            bool is_separator = !at_end
                && (stem[i] == '.' || stem[i] == '_' || stem[i] == '-');
            if (!at_end && !is_separator)
                continue;

            if (i > token_start)
                tokens += stem.substring (token_start, i - token_start);

            token_start = i + 1;
        }

        return tokens;
    }

    private string normalize_language_guess_token (string token) {
        return token.strip ().down ();
    }

    private bool is_known_language_code (string code, bool force_fallback) {
        string normalized = normalize_language_guess_token (code);
        if (normalized.length < 2 || normalized.length > 3)
            return false;

        for (int i = 0; i < normalized.length; i++) {
            char c = normalized[i];
            if (c < 'a' || c > 'z')
                return false;
        }

        return get_known_language_codes (force_fallback).contains (normalized);
    }

    private bool is_known_region_code (string code, bool force_fallback) {
        string normalized = normalize_language_guess_token (code);
        if (normalized.length != 2)
            return false;

        for (int i = 0; i < normalized.length; i++) {
            char c = normalized[i];
            if (c < 'a' || c > 'z')
                return false;
        }

        return get_known_region_codes (force_fallback).contains (normalized);
    }

    private TokenKind classify_token (string raw_token,
                                      string normalized_token,
                                      bool force_language_fallback,
                                      bool force_region_fallback) {
        if (normalized_token.length == 0)
            return TokenKind.UNKNOWN;
        if (is_non_language_subtitle_tag (normalized_token))
            return TokenKind.SUBTITLE_TAG;
        if (is_blocked_language_code (normalized_token))
            return TokenKind.BLOCKED_CODE;
        if (is_ambiguous_language_tag (normalized_token)
            && is_known_language_code (normalized_token, force_language_fallback))
            return TokenKind.AMBIGUOUS_LANGUAGE;
        if (is_known_language_code (normalized_token, force_language_fallback))
            return TokenKind.LANGUAGE;
        if (is_region_suffix_token (raw_token)
            && is_known_region_code (normalized_token, force_region_fallback))
            return TokenKind.REGION;
        return TokenKind.UNKNOWN;
    }

    private bool is_ambiguous_language_tag (string token) {
        switch (token) {
            case "hi":
            case "sd":
                return true;
            default:
                return false;
        }
    }

    private bool is_non_language_subtitle_tag (string token) {
        switch (token) {
            case "cc":
            case "dc":
            case "dub":
            case "forced":
            case "forc":
            case "hc":
            case "hdr":
            case "hd":
            case "hq":
            case "raw":
            case "rip":
            case "sdh":
            case "sub":
            case "uhd":
            case "vf":
            case "vo":
                return true;
            default:
                return false;
        }
    }

    private bool is_blocked_language_code (string token) {
        switch (token) {
            case "art":
            case "cpf":
            case "cpp":
            case "cpe":
            case "crp":
            case "map":
            case "mis":
            case "mul":
            case "nai":
            case "sgn":
            case "und":
            case "zxx":
                return true;
            default:
                return false;
        }
    }

    private bool is_region_suffix_token (string token) {
        if (token.length != 2)
            return false;

        for (int i = 0; i < token.length; i++) {
            char c = token[i];
            if ((c < 'A' || c > 'Z') && (c < 'a' || c > 'z'))
                return false;
        }

        return true;
    }

    private HashTable<string, bool> get_known_language_codes (bool force_fallback) {
        if (force_fallback) {
            if (fallback_language_codes == null) {
                fallback_language_codes = new HashTable<string, bool> (str_hash, str_equal);
                seed_fallback_language_codes (fallback_language_codes);
            }
            return fallback_language_codes;
        }

        if (known_language_codes == null) {
            known_language_codes = new HashTable<string, bool> (str_hash, str_equal);

            bool loaded = load_language_codes_from_json (
                "/usr/share/iso-codes/json/iso_639-2.json", "639-2", known_language_codes);

            if (!loaded)
                seed_fallback_language_codes (known_language_codes);
        }

        return known_language_codes;
    }

    private HashTable<string, bool> get_known_region_codes (bool force_fallback) {
        if (force_fallback) {
            if (fallback_region_codes == null) {
                fallback_region_codes = new HashTable<string, bool> (str_hash, str_equal);
                seed_fallback_region_codes (fallback_region_codes);
            }
            return fallback_region_codes;
        }

        if (known_region_codes == null) {
            known_region_codes = new HashTable<string, bool> (str_hash, str_equal);

            bool loaded = load_region_codes_from_json (
                "/usr/share/iso-codes/json/iso_3166-1.json", "3166-1", known_region_codes);

            if (!loaded)
                seed_fallback_region_codes (known_region_codes);
        }

        return known_region_codes;
    }

    private bool load_language_codes_from_json (string path,
                                                string array_name,
                                                HashTable<string, bool> table) {
        try {
            string json_text;
            size_t json_length;
            FileUtils.get_contents (path, out json_text, out json_length);

            var parser = new Json.Parser ();
            parser.load_from_data (json_text);

            Json.Node? root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return false;

            Json.Object root_obj = root.get_object ();
            if (!root_obj.has_member (array_name))
                return false;

            Json.Array codes = root_obj.get_array_member (array_name);
            for (uint i = 0; i < codes.get_length (); i++) {
                Json.Object? entry = codes.get_object_element (i);
                if (entry == null || !is_guessable_language_entry (entry))
                    continue;

                add_language_code (table, entry.get_string_member_with_default ("alpha_2", ""));
                add_language_code (table, entry.get_string_member_with_default ("alpha_3", ""));
                add_language_code (table, entry.get_string_member_with_default ("bibliographic", ""));
            }

            return table.size () > 0;
        } catch (Error e) {
            warning ("SubtitleLanguageGuesser: Failed to load ISO 639 codes from %s: %s",
                path, e.message);
            return false;
        }
    }

    private bool load_region_codes_from_json (string path,
                                              string array_name,
                                              HashTable<string, bool> table) {
        try {
            string json_text;
            size_t json_length;
            FileUtils.get_contents (path, out json_text, out json_length);

            var parser = new Json.Parser ();
            parser.load_from_data (json_text);

            Json.Node? root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return false;

            Json.Object root_obj = root.get_object ();
            if (!root_obj.has_member (array_name))
                return false;

            Json.Array codes = root_obj.get_array_member (array_name);
            for (uint i = 0; i < codes.get_length (); i++) {
                Json.Object? entry = codes.get_object_element (i);
                if (entry == null)
                    continue;

                string alpha_2 = normalize_language_guess_token (
                    entry.get_string_member_with_default ("alpha_2", ""));
                if (alpha_2.length == 2)
                    table.insert (alpha_2, true);
            }

            return table.size () > 0;
        } catch (Error e) {
            warning ("SubtitleLanguageGuesser: Failed to load ISO 3166 codes from %s: %s",
                path, e.message);
            return false;
        }
    }

    private bool is_guessable_language_entry (Json.Object entry) {
        string name = entry.get_string_member_with_default ("name", "").strip ().down ();
        if (name.length == 0)
            return false;

        if (name.contains (" languages"))
            return false;
        if (name.contains ("creoles and pidgins"))
            return false;

        switch (name) {
            case "multiple languages":
            case "no linguistic content; not applicable":
            case "uncoded languages":
            case "undetermined":
                return false;
            default:
                return true;
        }
    }

    private void add_language_code (HashTable<string, bool> table, string code) {
        string normalized = code.strip ().down ();
        if (normalized.length >= 2 && normalized.length <= 3)
            table.insert (normalized, true);
    }

    private void seed_fallback_language_codes (HashTable<string, bool> table) {
        string[] fallback_codes = {
            "aa", "aar", "ab", "abk", "ace", "ach", "ada", "ady", "ae", "af",
            "afh", "afr", "ain", "ak", "aka", "akk", "alb", "ale", "alt", "am",
            "amh", "an", "ang", "anp", "ar", "ara", "arc", "arg", "arm", "arn",
            "arp", "arw", "as", "asm", "ast", "av", "ava", "ave", "awa", "ay",
            "aym", "az", "aze", "ba", "bak", "bal", "bam", "ban", "baq", "bas",
            "be", "bej", "bel", "bem", "ben", "bg", "bho", "bi", "bik", "bin",
            "bis", "bla", "bm", "bn", "bo", "bod", "bos", "br", "bra", "bre",
            "bs", "bua", "bug", "bul", "bur", "byn", "ca", "cad", "car", "cat",
            "ce", "ceb", "ces", "ch", "cha", "chb", "che", "chg", "chi", "chk",
            "chm", "chn", "cho", "chp", "chr", "chu", "chv", "chy", "cnr", "co",
            "cop", "cor", "cos", "cr", "cre", "crh",
            "cs", "csb", "cu", "cv", "cy", "cym", "cze", "da", "dak", "dan",
            "dar", "de", "del", "den", "deu", "dgr", "din", "div", "doi", "dsb",
            "dua", "dum", "dut", "dv", "dyu", "dz", "dzo", "ee", "efi", "egy",
            "eka", "el", "ell", "elx", "en", "eng", "enm", "eo", "epo", "es",
            "est", "et", "eu", "eus", "ewe", "ewo", "fa", "fan", "fao", "fas",
            "fat", "ff", "fi", "fij", "fil", "fin", "fj", "fo", "fon", "fr",
            "fra", "fre", "frm", "fro", "frr", "frs", "fry", "ful", "fur", "fy",
            "ga", "gaa", "gay", "gba", "gd", "geo", "ger", "gez", "gil", "gl",
            "gla", "gle", "glg", "glv", "gmh", "gn", "goh", "gon", "gor", "got",
            "grb", "grc", "gre", "grn", "gsw", "gu", "guj", "gv", "gwi", "ha",
            "hai", "hat", "hau", "haw", "he", "heb", "her", "hi", "hil", "hin",
            "hit", "hmn", "hmo", "ho", "hr", "hrv", "hsb", "ht", "hu", "hun",
            "hup", "hy", "hye", "hz", "ia", "iba", "ibo", "ice", "id", "ido",
            "ie", "ig", "ii", "iii", "ik", "iku", "ile", "ilo", "ina", "ind",
            "inh", "io", "ipk", "is", "isl", "it", "ita", "iu", "ja", "jav",
            "jbo", "jpn", "jpr", "jrb", "jv", "ka", "kaa", "kab", "kac", "kal",
            "kam", "kan", "kas", "kat", "kau", "kaw", "kaz", "kbd", "kg", "kha",
            "khm", "kho", "ki", "kik", "kin", "kir", "kj", "kk", "kl", "km",
            "kmb", "kn", "ko", "kok", "kom", "kon", "kor", "kos", "kpe", "kr",
            "krc", "krl", "kru", "ks", "ku", "kua", "kum", "kur", "kut", "kv",
            "kw", "ky", "la", "lad", "lah", "lam", "lao", "lat", "lav", "lb",
            "lez", "lg", "li", "lim", "lin", "lit", "ln", "lo", "lol", "loz",
            "lt", "ltz", "lu", "lua", "lub", "lug", "lui", "lun", "luo", "lus",
            "lv", "mac", "mad", "mag", "mah", "mai", "mak", "mal", "man", "mao",
            "mar", "mas", "may", "mdf", "mdr", "men", "mg", "mga", "mh", "mi",
            "mic", "min", "mk", "mkd", "ml", "mlg", "mlt", "mn", "mnc", "mni",
            "moh", "mon", "mos", "mr", "mri", "ms", "msa", "mt", "mus", "mwl",
            "mwr", "my", "mya", "myv", "na", "nap", "nau", "nav", "nb", "nbl",
            "nd", "nde", "ndo", "nds", "ne", "nep", "new", "ng", "nia", "niu",
            "nl", "nld", "nn", "nno", "no", "nob", "nog", "non", "nor", "nqo",
            "nr", "nso", "nv", "nwc", "ny", "nya", "nym", "nyn", "nyo", "nzi",
            "oc", "oci", "oj", "oji", "om", "or", "ori", "orm", "os", "osa",
            "oss", "ota", "pa", "pag", "pal", "pam", "pan", "pap", "pau", "peo",
            "per", "phn", "pi", "pl", "pli", "pol", "pon", "por", "pro", "ps",
            "pt", "pus", "qu", "que", "raj", "rap", "rar", "rm", "rn", "ro",
            "roh", "rom", "ron", "ru", "rum", "run", "rup", "rus", "rw", "sa",
            "sad", "sag", "sah", "sam", "san", "sas", "sat", "sc", "scn", "sco",
            "sd", "se", "sel", "sg", "sga", "shn", "si", "sid", "sin", "sk",
            "sl", "slk", "slo", "slv", "sm", "sma", "sme", "smj", "smn", "smo",
            "sms", "sn", "sna", "snd", "snk", "so", "sog", "som", "sot", "spa",
            "sq", "sqi", "sr", "srd", "srn", "srp", "srr", "ss", "ssw", "st",
            "su", "suk", "sun", "sus", "sux", "sv", "sw", "swa", "swe", "syc",
            "syr", "ta", "tah", "tam", "tat", "te", "tel", "tem", "ter", "tet",
            "tg", "tgk", "tgl", "th", "tha", "ti", "tib", "tig", "tir", "tiv",
            "tk", "tkl", "tl", "tlh", "tli", "tmh", "tn", "to", "tog", "ton",
            "tpi", "tr", "ts", "tsi", "tsn", "tso", "tt", "tuk", "tum", "tur",
            "tvl", "tw", "twi", "ty", "tyv", "udm", "ug", "uga", "uig", "uk",
            "ukr", "umb", "ur", "urd", "uz", "uzb", "vai", "ve", "ven", "vi",
            "vie", "vo", "vol", "vot", "wa", "wal", "war", "was", "wel", "wln",
            "wo", "wol", "xal", "xh", "xho", "yao", "yap", "yi", "yid", "yo",
            "yor", "za", "zap", "zbl", "zen", "zgh", "zh", "zha", "zho", "zu",
            "zul", "zun", "zza"
        };

        foreach (unowned string fallback_code in fallback_codes)
            table.insert (fallback_code, true);
    }

    private void seed_fallback_region_codes (HashTable<string, bool> table) {
        string[] fallback_codes = {
            "ad", "ae", "af", "ag", "ai", "al", "am", "ao", "aq", "ar", "as", "at",
            "au", "aw", "ax", "az", "ba", "bb", "bd", "be", "bf", "bg", "bh", "bi",
            "bj", "bl", "bm", "bn", "bo", "bq", "br", "bs", "bt", "bv", "bw", "by",
            "bz", "ca", "cc", "cd", "cf", "cg", "ch", "ci", "ck", "cl", "cm", "cn",
            "co", "cr", "cu", "cv", "cw", "cx", "cy", "cz", "de", "dj", "dk", "dm",
            "do", "dz", "ec", "ee", "eg", "eh", "er", "es", "et", "fi", "fj", "fk",
            "fm", "fo", "fr", "ga", "gb", "gd", "ge", "gf", "gg", "gh", "gi", "gl",
            "gm", "gn", "gp", "gq", "gr", "gs", "gt", "gu", "gw", "gy", "hk", "hm",
            "hn", "hr", "ht", "hu", "id", "ie", "il", "im", "in", "io", "iq", "ir",
            "is", "it", "je", "jm", "jo", "jp", "ke", "kg", "kh", "ki", "km", "kn",
            "kp", "kr", "kw", "ky", "kz", "la", "lb", "lc", "li", "lk", "lr", "ls",
            "lt", "lu", "lv", "ly", "ma", "mc", "md", "me", "mf", "mg", "mh", "mk",
            "ml", "mm", "mn", "mo", "mp", "mq", "mr", "ms", "mt", "mu", "mv", "mw",
            "mx", "my", "mz", "na", "nc", "ne", "nf", "ng", "ni", "nl", "no", "np",
            "nr", "nu", "nz", "om", "pa", "pe", "pf", "pg", "ph", "pk", "pl", "pm",
            "pn", "pr", "ps", "pt", "pw", "py", "qa", "re", "ro", "rs", "ru", "rw",
            "sa", "sb", "sc", "sd", "se", "sg", "sh", "si", "sj", "sk", "sl", "sm",
            "sn", "so", "sr", "ss", "st", "sv", "sx", "sy", "sz", "tc", "td", "tf",
            "tg", "th", "tj", "tk", "tl", "tm", "tn", "to", "tr", "tt", "tv", "tw",
            "tz", "ua", "ug", "um", "us", "uy", "uz", "va", "vc", "ve", "vg", "vi",
            "vn", "vu", "wf", "ws", "ye", "yt", "za", "zm", "zw"
        };

        foreach (unowned string fallback_code in fallback_codes)
            table.insert (fallback_code, true);
    }
}
