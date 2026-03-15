using GLib;

namespace SubtitleLanguageGuesser {
    private struct GuessToken {
        public string raw;
        public string normalized;
        public char separator_before;

        public GuessToken (string raw, string normalized, char separator_before) {
            this.raw = raw;
            this.normalized = normalized;
            this.separator_before = separator_before;
        }
    }

    private enum TokenKind {
        LANGUAGE,
        AMBIGUOUS_LANGUAGE,
        SCRIPT,
        REGION,
        SUBTITLE_TAG,
        BLOCKED_CODE,
        UNKNOWN
    }

    private enum LookupMode {
        DEFAULT,
        FORCE_FALLBACK
    }

    private HashTable<string, bool>? known_language_codes = null;
    private HashTable<string, bool>? fallback_language_codes = null;
    private HashTable<string, bool>? known_script_codes = null;
    private HashTable<string, bool>? fallback_script_codes = null;
    private HashTable<string, bool>? known_region_codes = null;
    private HashTable<string, bool>? fallback_region_codes = null;

    public string guess_from_path (string path) {
        return guess_from_path_internal (path, LookupMode.DEFAULT);
    }

#if SUBTITLE_LANGUAGE_GUESSER_TEST_BUILD
    internal string guess_from_path_for_tests (string path) {
        return guess_from_path_internal (path, LookupMode.FORCE_FALLBACK);
    }
#endif

    private string guess_from_path_internal (string path,
                                            LookupMode lookup_mode) {
        string bn = Path.get_basename (path);
        int dot = bn.last_index_of_char ('.');
        if (dot <= 0)
            return "und";

        string stem = bn.substring (0, dot);
        string? locale_guess = guess_language_from_locale_suffix (stem, lookup_mode);
        if (locale_guess != null)
            return locale_guess;

        GuessToken[] tokens = split_language_guess_tokens (stem);
        if (tokens.length == 0)
            return "und";

        string? guessed = guess_language_from_tokens (tokens, lookup_mode);
        return guessed ?? "und";
    }

    private string? guess_language_from_tokens (GuessToken[] tokens,
                                                LookupMode lookup_mode) {
        int last_index = tokens.length - 1;
        GuessToken last_token = tokens[last_index];

        switch (classify_token (
            last_token.raw,
            last_token.normalized,
            lookup_mode)) {
            case TokenKind.LANGUAGE:
                return last_token.normalized;
            case TokenKind.AMBIGUOUS_LANGUAGE:
                string? previous_language = find_previous_language_token (
                    tokens, last_index - 1, lookup_mode);
                if (previous_language != null)
                    return previous_language;
                return last_token.normalized;
            case TokenKind.SCRIPT:
                return try_resolve_script_pair (tokens, last_index, lookup_mode);
            case TokenKind.SUBTITLE_TAG:
            case TokenKind.BLOCKED_CODE:
                return find_previous_language_token (tokens, last_index - 1, lookup_mode);
            case TokenKind.REGION:
                return try_resolve_region_suffix (tokens, last_index, lookup_mode);
            case TokenKind.UNKNOWN:
            default:
                return null;
        }
    }

    private string? guess_language_from_locale_suffix (string stem,
                                                       LookupMode lookup_mode) {
        int region_sep = int.max (stem.last_index_of_char ('-'), stem.last_index_of_char ('_'));
        if (region_sep <= 0 || region_sep >= stem.length - 1)
            return null;

        string region = normalize_language_guess_token (stem.substring (region_sep + 1));
        if (!is_known_region_code (region, lookup_mode))
            return null;

        string prefix = stem.substring (0, region_sep);
        int language_sep = int.max (
            prefix.last_index_of_char ('.'),
            int.max (prefix.last_index_of_char ('_'), prefix.last_index_of_char ('-'))
        );

        string language = normalize_language_guess_token (
            language_sep >= 0 ? prefix.substring (language_sep + 1) : prefix);
        if (language.length != 2 || !is_known_language_code (language, lookup_mode))
            return null;

        return language;
    }

    private string? find_previous_language_token (GuessToken[] tokens,
                                                  int start_index,
                                                  LookupMode lookup_mode) {
        for (int i = start_index; i >= 0; i--) {
            GuessToken token = tokens[i];
            if (token.normalized.length == 0)
                continue;

            string? region_language = try_resolve_region_suffix (tokens, i, lookup_mode);
            if (region_language != null)
                return region_language;

            string? script_language = try_resolve_script_pair (tokens, i, lookup_mode);
            if (script_language != null)
                return script_language;

            switch (classify_token (
                token.raw,
                token.normalized,
                lookup_mode)) {
                case TokenKind.LANGUAGE:
                case TokenKind.AMBIGUOUS_LANGUAGE:
                    return token.normalized;
                case TokenKind.SCRIPT:
                case TokenKind.SUBTITLE_TAG:
                case TokenKind.BLOCKED_CODE:
                    continue;
                case TokenKind.REGION:
                case TokenKind.UNKNOWN:
                default:
                    break;
            }

            break;
        }

        return null;
    }

    private string? try_resolve_region_suffix (GuessToken[] tokens,
                                               int region_index,
                                               LookupMode lookup_mode) {
        string? locale_language = try_resolve_locale_pair (tokens, region_index, lookup_mode);
        if (locale_language != null)
            return locale_language;

        if (region_index <= 1)
            return null;

        GuessToken region_token = tokens[region_index];
        if ((region_token.separator_before != '-' && region_token.separator_before != '_')
            || !is_known_region_code (region_token.normalized, lookup_mode)) {
            return null;
        }

        return try_resolve_script_pair (tokens, region_index - 1, lookup_mode);
    }

    private string? try_resolve_locale_pair (GuessToken[] tokens,
                                             int region_index,
                                             LookupMode lookup_mode) {
        if (region_index <= 0)
            return null;

        GuessToken region_token = tokens[region_index];
        if ((region_token.separator_before != '-' && region_token.separator_before != '_')
            || !is_known_region_code (region_token.normalized, lookup_mode)) {
            return null;
        }

        GuessToken language_token = tokens[region_index - 1];
        if (language_token.normalized.length != 2
            || !is_known_language_code (language_token.normalized, lookup_mode)) {
            return null;
        }

        return language_token.normalized;
    }

    private string? try_resolve_script_pair (GuessToken[] tokens,
                                             int script_index,
                                             LookupMode lookup_mode) {
        if (script_index <= 0)
            return null;

        GuessToken script_token = tokens[script_index];
        if ((script_token.separator_before != '-' && script_token.separator_before != '_')
            || !is_known_script_code (script_token.normalized, lookup_mode)) {
            return null;
        }

        GuessToken language_token = tokens[script_index - 1];
        if (language_token.normalized.length != 2
            || !is_known_language_code (language_token.normalized, lookup_mode)) {
            return null;
        }

        return language_token.normalized;
    }

    private GuessToken[] split_language_guess_tokens (string stem) {
        GuessToken[] tokens = {};
        int token_start = 0;
        char separator_before = '\0';

        for (int i = 0; i <= stem.length; i++) {
            bool at_end = (i == stem.length);
            char current_char = at_end ? '\0' : stem[i];
            bool is_separator = !at_end
                && (current_char == '.' || current_char == '_' || current_char == '-');
            if (!at_end && !is_separator)
                continue;

            if (i > token_start) {
                string raw = stem.substring (token_start, i - token_start);
                tokens += GuessToken (
                    raw,
                    normalize_language_guess_token (raw),
                    separator_before
                );
            }

            token_start = i + 1;
            separator_before = current_char;
        }

        return tokens;
    }

    private string normalize_language_guess_token (string token) {
        return token.strip ().down ();
    }

    private bool is_known_language_code (string code, LookupMode lookup_mode) {
        string normalized = normalize_language_guess_token (code);
        if (normalized.length < 2 || normalized.length > 3)
            return false;

        for (int i = 0; i < normalized.length; i++) {
            char c = normalized[i];
            if (c < 'a' || c > 'z')
                return false;
        }

        return get_known_language_codes (lookup_mode).contains (normalized);
    }

    private bool is_known_region_code (string code, LookupMode lookup_mode) {
        string normalized = normalize_language_guess_token (code);
        if (!is_region_code_format (normalized))
            return false;

        return get_known_region_codes (lookup_mode).contains (normalized);
    }

    private bool is_known_script_code (string code, LookupMode lookup_mode) {
        string normalized = normalize_language_guess_token (code);
        if (normalized.length != 4)
            return false;

        for (int i = 0; i < normalized.length; i++) {
            char c = normalized[i];
            if (c < 'a' || c > 'z')
                return false;
        }

        return get_known_script_codes (lookup_mode).contains (normalized);
    }

    private TokenKind classify_token (string raw_token,
                                      string normalized_token,
                                      LookupMode lookup_mode) {
        if (normalized_token.length == 0)
            return TokenKind.UNKNOWN;
        if (is_non_language_subtitle_tag (normalized_token))
            return TokenKind.SUBTITLE_TAG;
        if (is_blocked_language_code (normalized_token))
            return TokenKind.BLOCKED_CODE;
        if (is_ambiguous_language_tag (normalized_token)
            && is_known_language_code (normalized_token, lookup_mode))
            return TokenKind.AMBIGUOUS_LANGUAGE;
        if (is_known_language_code (normalized_token, lookup_mode))
            return TokenKind.LANGUAGE;
        if ((raw_token.length == 4 || normalized_token.length == 4)
            && is_known_script_code (normalized_token, lookup_mode))
            return TokenKind.SCRIPT;
        if (is_region_suffix_token (raw_token)
            && is_known_region_code (normalized_token, lookup_mode))
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
        return is_region_code_format (token);
    }

    private bool is_region_code_format (string token) {
        if (token.length == 2) {
            for (int i = 0; i < token.length; i++) {
                char c = token[i];
                if ((c < 'A' || c > 'Z') && (c < 'a' || c > 'z'))
                    return false;
            }

            return true;
        }

        if (token.length == 3) {
            for (int i = 0; i < token.length; i++) {
                char c = token[i];
                if (c < '0' || c > '9')
                    return false;
            }

            return true;
        }

        return false;
    }

    private HashTable<string, bool> get_known_language_codes (LookupMode lookup_mode) {
        if (lookup_mode == LookupMode.FORCE_FALLBACK) {
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

    private HashTable<string, bool> get_known_script_codes (LookupMode lookup_mode) {
        if (lookup_mode == LookupMode.FORCE_FALLBACK) {
            if (fallback_script_codes == null) {
                fallback_script_codes = new HashTable<string, bool> (str_hash, str_equal);
                seed_fallback_script_codes (fallback_script_codes);
            }
            return fallback_script_codes;
        }

        if (known_script_codes == null) {
            known_script_codes = new HashTable<string, bool> (str_hash, str_equal);

            bool loaded = load_script_codes_from_json (
                "/usr/share/iso-codes/json/iso_15924.json", "15924", known_script_codes);

            if (!loaded)
                seed_fallback_script_codes (known_script_codes);
        }

        return known_script_codes;
    }

    private HashTable<string, bool> get_known_region_codes (LookupMode lookup_mode) {
        if (lookup_mode == LookupMode.FORCE_FALLBACK) {
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

    private bool load_script_codes_from_json (string path,
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

                string alpha_4 = normalize_language_guess_token (
                    entry.get_string_member_with_default ("alpha_4", ""));
                if (alpha_4.length == 4)
                    table.insert (alpha_4, true);
            }

            return table.size () > 0;
        } catch (Error e) {
            warning ("SubtitleLanguageGuesser: Failed to load ISO 15924 codes from %s: %s",
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

                string numeric = entry.get_string_member_with_default ("numeric", "").strip ();
                if (numeric.length == 3 && is_region_code_format (numeric))
                    table.insert (numeric, true);
            }

            seed_common_numeric_region_codes (table);
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

        seed_common_numeric_region_codes (table);
    }

    private void seed_common_numeric_region_codes (HashTable<string, bool> table) {
        string[] fallback_codes = {
            "001", "002", "003", "005", "009", "011", "013", "014", "015", "017",
            "018", "019", "021", "029", "030", "034", "035", "039", "053", "054",
            "057", "061", "142", "143", "145", "150", "151", "154", "155", "202",
            "419"
        };

        foreach (unowned string fallback_code in fallback_codes)
            table.insert (fallback_code, true);
    }

    private void seed_fallback_script_codes (HashTable<string, bool> table) {
        string[] fallback_codes = {
            "arab", "beng", "cyrl", "deva", "grek", "gujr", "guru",
            "hans", "hant", "hebr", "jpan", "kore", "latn", "taml", "thai"
        };

        foreach (unowned string fallback_code in fallback_codes)
            table.insert (fallback_code, true);
    }
}
