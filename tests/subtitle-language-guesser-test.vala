using GLib;

private void assert_guess (string path, string expected) {
    string actual = SubtitleLanguageGuesser.guess_from_path (path);
    if (actual != expected) {
        Test.fail_printf ("guess_from_path(%s) => %s, expected %s", path, actual, expected);
    }
}

private void assert_guess_with_fallback (string path, string expected) {
    string actual = SubtitleLanguageGuesser.guess_from_path_for_tests (path);
    if (actual != expected) {
        Test.fail_printf ("fallback guess_from_path(%s) => %s, expected %s", path, actual, expected);
    }
}

private void test_guess_language_common_codes () {
    assert_guess ("movie.eng.srt", "eng");
    assert_guess ("movie_spa.srt", "spa");
    assert_guess ("movie-jpn.srt", "jpn");
}

private void test_guess_language_subtitle_tags () {
    assert_guess ("movie.hi.srt", "hi");
    assert_guess ("movie.eng.hi.srt", "eng");
    assert_guess ("movie.sdh.srt", "und");
    assert_guess ("movie.eng.sdh.srt", "eng");
    assert_guess ("movie.dub.srt", "und");
    assert_guess ("movie.eng.dub.srt", "eng");
    assert_guess ("movie.forced.srt", "und");
    assert_guess ("movie.eng.forced.srt", "eng");
    assert_guess ("movie.eng.forc.srt", "eng");
    assert_guess ("movie.eng.forced.sdh.cc.dub.srt", "eng");
    assert_guess ("movie.pt-BR.forced.srt", "pt");
    assert_guess ("movie.en-US.hi.srt", "en");
    assert_guess ("movie.zh-Hant.forced.srt", "zh");
    assert_guess ("movie.sr-Latn.sdh.srt", "sr");
}

private void test_guess_language_script_suffixes () {
    assert_guess ("movie.zh-Hant.srt", "zh");
    assert_guess ("movie.zh_Hant.srt", "zh");
    assert_guess ("movie.sr-Latn.srt", "sr");
    assert_guess ("movie.sr_Latn.srt", "sr");
    assert_guess ("movie.zh-Hant-001.srt", "zh");
    assert_guess ("movie.zh-Hant-US.srt", "zh");
    assert_guess ("movie.zh_Hant_US.srt", "zh");
    assert_guess ("movie.zh-Hans-419.srt", "zh");
    assert_guess ("movie.zh_Hans_419.srt", "zh");
    assert_guess ("movie.sr-Latn-RS.srt", "sr");
    assert_guess ("movie.sr_Latn_RS.srt", "sr");
}

private void test_guess_language_non_language_suffixes () {
    assert_guess ("movie.720.srt", "und");
    assert_guess ("movie.720p.srt", "und");
    assert_guess ("movie.web.srt", "und");
    assert_guess ("movie.cam.srt", "und");
    assert_guess ("movie.art.srt", "und");
    assert_guess ("movie.cpe.srt", "und");
    assert_guess ("movie.cpf.srt", "und");
    assert_guess ("movie.cpp.srt", "und");
    assert_guess ("movie.crp.srt", "und");
    assert_guess ("movie.map.srt", "und");
    assert_guess ("movie.zxx.srt", "und");
    assert_guess ("movie.eng.web.srt", "und");
    assert_guess ("movie.eng.fixed.srt", "und");
    assert_guess ("movie.eng.720.srt", "und");
    assert_guess ("movie.en.001.srt", "und");
    assert_guess ("movie.es.419.srt", "und");
    assert_guess ("movie.zh-Hans-720.srt", "und");
    assert_guess ("movie.pt-BR.720.srt", "und");
}

private void test_guess_language_locale_suffix_hyphen_uppercase () {
    assert_guess ("movie.en-US.srt", "en");
    assert_guess ("movie-en-US.srt", "en");
    assert_guess ("movie.pt-BR.srt", "pt");
    assert_guess ("movie.en-001.srt", "en");
    assert_guess ("movie.es-419.srt", "es");
}

private void test_guess_language_locale_suffix_hyphen_case_variants () {
    assert_guess ("movie.en-us.srt", "en");
    assert_guess ("movie.en-Us.srt", "en");
    assert_guess ("movie.pt-br.srt", "pt");
}

private void test_guess_language_locale_suffix_underscore () {
    assert_guess ("movie_en_US.srt", "en");
    assert_guess ("movie_en_001.srt", "en");
    assert_guess ("movie_es_419.srt", "es");
}

private void test_guess_language_trailing_language_token_wins () {
    assert_guess ("movie.eng.es.srt", "es");
    assert_guess ("movie.fr.en.srt", "en");
    assert_guess ("movie.eng-es.srt", "es");
    assert_guess ("movie.eng.und.srt", "eng");
}

private void test_guess_language_fallback_mode_matches_primary () {
    assert_guess_with_fallback ("movie.eng.srt", "eng");
    assert_guess_with_fallback ("movie.en-US.srt", "en");
    assert_guess_with_fallback ("movie-en-US.srt", "en");
    assert_guess_with_fallback ("movie.pt-BR.forced.srt", "pt");
    assert_guess_with_fallback ("movie.en-US.hi.srt", "en");
    assert_guess_with_fallback ("movie.en-001.srt", "en");
    assert_guess_with_fallback ("movie_en_001.srt", "en");
    assert_guess_with_fallback ("movie.es-419.srt", "es");
    assert_guess_with_fallback ("movie_es_419.srt", "es");
    assert_guess_with_fallback ("movie.zh-Hant.srt", "zh");
    assert_guess_with_fallback ("movie.zh_Hant.srt", "zh");
    assert_guess_with_fallback ("movie.zh-Hant-001.srt", "zh");
    assert_guess_with_fallback ("movie.zh-Hant-US.srt", "zh");
    assert_guess_with_fallback ("movie.zh_Hant_US.srt", "zh");
    assert_guess_with_fallback ("movie.zh-Hans-419.srt", "zh");
    assert_guess_with_fallback ("movie.zh_Hans_419.srt", "zh");
    assert_guess_with_fallback ("movie.zh-Hant.forced.srt", "zh");
    assert_guess_with_fallback ("movie.sr-Latn.srt", "sr");
    assert_guess_with_fallback ("movie.sr_Latn.srt", "sr");
    assert_guess_with_fallback ("movie.sr-Latn-RS.srt", "sr");
    assert_guess_with_fallback ("movie.sr_Latn_RS.srt", "sr");
    assert_guess_with_fallback ("movie.sr-Latn.sdh.srt", "sr");
    assert_guess_with_fallback ("movie.eng.sdh.srt", "eng");
    assert_guess_with_fallback ("movie.eng.und.srt", "eng");
    assert_guess_with_fallback ("movie.eng.720.srt", "und");
    assert_guess_with_fallback ("movie.en.001.srt", "und");
    assert_guess_with_fallback ("movie.es.419.srt", "und");
    assert_guess_with_fallback ("movie.zh-Hans-720.srt", "und");
    assert_guess_with_fallback ("movie.pt-BR.720.srt", "und");
    assert_guess_with_fallback ("movie.cpe.srt", "und");
    assert_guess_with_fallback ("movie.cpf.srt", "und");
    assert_guess_with_fallback ("movie.cpp.srt", "und");
    assert_guess_with_fallback ("movie.crp.srt", "und");
    assert_guess_with_fallback ("movie.art.srt", "und");
    assert_guess_with_fallback ("movie.map.srt", "und");
    assert_guess_with_fallback ("movie.zxx.srt", "und");
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/subtitle-language-guesser/common-codes", test_guess_language_common_codes);
    Test.add_func ("/subtitle-language-guesser/subtitle-tags", test_guess_language_subtitle_tags);
    Test.add_func ("/subtitle-language-guesser/script-suffixes", test_guess_language_script_suffixes);
    Test.add_func ("/subtitle-language-guesser/non-language-suffixes", test_guess_language_non_language_suffixes);
    Test.add_func ("/subtitle-language-guesser/locale-suffixes/hyphen-uppercase", test_guess_language_locale_suffix_hyphen_uppercase);
    Test.add_func ("/subtitle-language-guesser/locale-suffixes/hyphen-case-variants", test_guess_language_locale_suffix_hyphen_case_variants);
    Test.add_func ("/subtitle-language-guesser/locale-suffixes/underscore", test_guess_language_locale_suffix_underscore);
    Test.add_func ("/subtitle-language-guesser/trailing-language-token-wins", test_guess_language_trailing_language_token_wins);
    Test.add_func ("/subtitle-language-guesser/fallback-mode-matches-primary", test_guess_language_fallback_mode_matches_primary);

    Test.run ();
}
