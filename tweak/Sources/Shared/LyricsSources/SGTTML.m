// TTML, the shape Apple Music writes its lyrics in and the one BiniLyrics and Unison serve.
//
// <p begin="0:13.148" end="0:15.705" ttm:agent="v1">
//   <span begin="0:13.148" end="0:13.385">You</span> <span …>called</span>
//   <span ttm:role="x-bg"><span begin="0:15.083" end="0:15.401">(Aye,</span> …</span>
// </p>
//
// Two things here exist in no other source the mod reads. ttm:agent names the voice, which is how a
// duet ends up on two sides of the page; a span with the x-bg role holds the backing vocals sung
// under the line. The third is quieter but matters more: the spans of a Japanese or Chinese line sit
// flush against each other with no whitespace between them, and that is the only way to tell that a
// syllable continues a word rather than starting one.
#import "LyricsSources.h"

// A begin or end: seconds ("1.241"), minutes ("0:01.241"), hours ("1:02:03.456"), or a clock value
// with a unit after it ("1.5s", "500ms"). Negative on a value that is none of these.
static NSInteger msOfClock(NSString *clock) {
    NSString *text = [clock stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return -1;
    double scale = 1000;
    if ([text hasSuffix:@"ms"]) {
        scale = 1;
        text = [text substringToIndex:text.length - 2];
    } else if ([text hasSuffix:@"s"]) {
        text = [text substringToIndex:text.length - 1];
    }
    double total = 0;
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
    if (parts.count > 3) return -1;
    for (NSString *part in parts) {
        if (!part.length || [part rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789."].invertedSet].location != NSNotFound) return -1;
        total = total * 60 + part.doubleValue;
    }
    return (NSInteger)llround(total * (parts.count > 1 ? 1000 : scale));
}

// The words of one container: a <p>, or the x-bg span inside it.
@interface SGTTMLContainer : NSObject
@property (nonatomic, strong) NSMutableArray<SGKaraokeWord *> *words;
@property (nonatomic) BOOL spaced;   // whitespace has gone by, so the next word is not joined
@end

@implementation SGTTMLContainer
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _words = [NSMutableArray array];
    _spaced = YES;
    return self;
}
@end

@interface SGTTMLReader : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<SGKaraokeLine *> *lines;
@end

@implementation SGTTMLReader {
    NSMutableArray<SGTTMLContainer *> *_stack;   // the <p>, then its x-bg span while one is open
    SGTTMLContainer *_backing;                   // the x-bg container of the line being read
    NSInteger _lineStart, _lineEnd;
    NSString *_voice, *_lineKey;
    NSMutableString *_plain;                     // every character of the line, for a line-timed <p>
    NSMutableString *_translation;               // optional x-translation/ruby text kept off the sung line
    NSMutableString *_pronunciation;             // optional x-transliteration/x-pronunciation text
    NSMutableString *_word;                      // the characters of the span being read
    NSInteger _wordStart, _wordEnd;
    NSUInteger _spanDepth, _bgDepth, _wordDepth, _translationDepth, _pronunciationDepth;
    BOOL _translationAllowed;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lines = [NSMutableArray array];
    _stack = [NSMutableArray array];
    return self;
}

- (SGTTMLContainer *)top {
    return _stack.lastObject;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    if ([element isEqualToString:@"p"]) {
        [_stack removeAllObjects];
        [_stack addObject:[SGTTMLContainer new]];
        _backing = nil;
        _word = nil;
        _spanDepth = _bgDepth = _wordDepth = 0;
        _translationDepth = _pronunciationDepth = 0;
        _translationAllowed = YES;
        _plain = [NSMutableString string];
        _translation = [NSMutableString string];
        _pronunciation = [NSMutableString string];
        _lineStart = msOfClock(attributes[@"begin"]);
        _lineEnd = msOfClock(attributes[@"end"]);
        _voice = attributes[@"ttm:agent"] ?: attributes[@"agent"];
        _lineKey = attributes[@"itunes:key"] ?: attributes[@"key"];
        return;
    }
    if (![element isEqualToString:@"span"] || !_stack.count) return;
    _spanDepth++;
    NSString *role = attributes[@"ttm:role"] ?: attributes[@"role"];
    if ([role isEqualToString:@"x-bg"] && !_backing) {
        _backing = [SGTTMLContainer new];
        [_stack addObject:_backing];
        _bgDepth = _spanDepth;
        return;
    }
    NSString *lowerRole = role.lowercaseString;
    BOOL translation = [lowerRole containsString:@"translation"] || [lowerRole containsString:@"translated"];
    BOOL pronunciation = [lowerRole containsString:@"pronunciation"] || [lowerRole containsString:@"roman"]
                       || [lowerRole containsString:@"romanisation"] || [lowerRole containsString:@"transliteration"];
    if (translation || pronunciation) {
        // A selected language is only applied when the source labels its span. Unlabelled text is
        // kept as the useful fallback, which is how older BiniLyrics documents are written.
        NSString *language = attributes[@"xml:lang"] ?: attributes[@"lang"];
        if (translation) {
            NSArray<NSString *> *languageCodes = @[@"auto", @"ko", @"en", @"ja", @"zh"];
            NSInteger languageIndex = [NSUserDefaults.standardUserDefaults integerForKey:SGKeyLyricsTranslationLanguage];
            NSString *want = languageIndex >= 0 && languageIndex < (NSInteger)languageCodes.count
                           ? languageCodes[(NSUInteger)languageIndex] : @"auto";
            _translationAllowed = !want.length || [want isEqualToString:@"auto"] || !language.length
                                || [language.lowercaseString hasPrefix:want.lowercaseString];
        } else {
            // Pronunciation is a transliteration track, not a translation-language choice.
            _translationAllowed = YES;
        }
        if (translation) _translationDepth = _spanDepth;
        if (pronunciation) _pronunciationDepth = _spanDepth;
        return;
    }
    // A span nested inside one that is already being read is ruby or a translation: its characters
    // belong to the word around it rather than making a word of their own.
    if (_word || _translationDepth || _pronunciationDepth) return;
    NSInteger start = msOfClock(attributes[@"begin"]), end = msOfClock(attributes[@"end"]);
    if (start < 0) return;
    _word = [NSMutableString string];
    _wordStart = start;
    _wordEnd = MAX(end, start);
    _wordDepth = _spanDepth;
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)characters {
    if (!_stack.count) return;
    if (_translationDepth) {
        if (_translationAllowed) [_translation appendString:characters];
        return;
    }
    if (_pronunciationDepth) {
        if (_translationAllowed) [_pronunciation appendString:characters];
        return;
    }
    [_plain appendString:characters];
    if (_word) {
        [_word appendString:characters];
        return;
    }
    // Whitespace between two spans is the only record that a space belongs between the words.
    if ([characters stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return;
    if (characters.length) self.top.spaced = YES;
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)qualified {
    if ([element isEqualToString:@"p"]) {
        [self finishLine];
        [_stack removeAllObjects];
        return;
    }
    if (![element isEqualToString:@"span"] || !_stack.count) return;
    if (_translationDepth && _spanDepth == _translationDepth) _translationDepth = 0;
    if (_pronunciationDepth && _spanDepth == _pronunciationDepth) _pronunciationDepth = 0;
    if (_word && _spanDepth == _wordDepth) {
        NSString *text = [_word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        SGTTMLContainer *into = self.top;
        if (text.length) {
            SGKaraokeWord *word = [SGKaraokeWord new];
            word.text = text;
            word.start = _wordStart;
            word.end = _wordEnd;
            word.joined = into.words.count > 0 && !into.spaced;
            [into.words addObject:word];
            into.spaced = NO;
        }
        _word = nil;
        _wordDepth = 0;
    }
    if (_bgDepth && _spanDepth == _bgDepth) {
        [_stack removeLastObject];
        _bgDepth = 0;
    }
    if (_spanDepth) _spanDepth--;
}

- (SGKaraokeLine *)lineFrom:(NSArray<SGKaraokeWord *> *)words {
    if (!words.count) return nil;
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = words.firstObject.start;
    line.end = MAX(words.lastObject.end, line.start);
    return line;
}

- (void)finishLine {
    SGTTMLContainer *main = _stack.firstObject;
    SGKaraokeLine *line = [self lineFrom:main.words];
    // A document timed only by the line has no spans: its words are estimated, as Spotify's are.
    if (!line) {
        NSString *text = [_plain stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!text.length || _lineStart < 0) return;
        NSInteger end = MAX(_lineEnd, _lineStart);
        line = [SGKaraokeEstimatedLines(@[@(_lineStart), @(end)], @[text, @""]) firstObject];
        if (!line) return;
    }
    if (_lineStart >= 0) line.start = _lineStart;
    if (_lineEnd > line.start) line.end = _lineEnd;
    line.sourceKey = _lineKey;
    line.voice = _voice;
    line.backing = [self lineFrom:_backing.words];
    NSString *translation = [_translation stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *pronunciation = [_pronunciation stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (translation.length) line.translationText = translation;
    if (pronunciation.length) line.pronunciationText = pronunciation;
    [_lines addObject:line];
}

@end

// Apple-style translations and transliterations live in <head> and are linked to a body line by
// its itunes:key. This second, deliberately small parser keeps those auxiliary tracks separate from
// the main word parser above, including their optional word timestamps.
@interface SGTTMLAuxReader : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, SGKaraokeLine *> *> *entries;
@end

@implementation SGTTMLAuxReader {
    NSString *_kind, *_language, *_textKey;
    NSMutableString *_plain, *_word;
    NSMutableArray<SGKaraokeWord *> *_words;
    NSInteger _wordStart, _wordEnd;
    NSUInteger _spanDepth, _wordDepth;
    BOOL _allowed;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _entries = [NSMutableDictionary dictionary];
    return self;
}

- (BOOL)languageAllowed:(NSString *)language kind:(NSString *)kind {
    if (![kind isEqualToString:@"translation"]) return YES;
    NSArray<NSString *> *codes = @[@"auto", @"ko", @"en", @"ja", @"zh"];
    NSInteger index = [NSUserDefaults.standardUserDefaults integerForKey:SGKeyLyricsTranslationLanguage];
    NSString *want = index >= 0 && index < (NSInteger)codes.count ? codes[(NSUInteger)index] : @"auto";
    return !language.length || [want isEqualToString:@"auto"] || [language.lowercaseString hasPrefix:want];
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    if ([element isEqualToString:@"translation"] || [element isEqualToString:@"transliteration"]) {
        _kind = [element isEqualToString:@"translation"] ? @"translation" : @"pronunciation";
        _language = (attributes[@"xml:lang"] ?: attributes[@"lang"]).lowercaseString;
        _allowed = [self languageAllowed:_language kind:_kind];
        return;
    }
    if ([element isEqualToString:@"text"] && _kind.length) {
        _textKey = attributes[@"for"];
        _plain = [NSMutableString string];
        _words = [NSMutableArray array];
        _word = nil;
        _spanDepth = _wordDepth = 0;
        return;
    }
    if (![element isEqualToString:@"span"] || !_textKey.length) return;
    _spanDepth++;
    if (_word) return;
    NSInteger start = msOfClock(attributes[@"begin"]), end = msOfClock(attributes[@"end"]);
    if (start < 0) return;
    _word = [NSMutableString string];
    _wordStart = start;
    _wordEnd = MAX(end, start);
    _wordDepth = _spanDepth;
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)characters {
    if (!_textKey.length || !_allowed) return;
    [_plain appendString:characters];
    if (_word) [_word appendString:characters];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)qualified {
    if ([element isEqualToString:@"span"] && _textKey.length) {
        if (_word && _spanDepth == _wordDepth) {
            NSString *text = [_word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (text.length && _allowed) {
                SGKaraokeWord *word = [SGKaraokeWord new];
                word.text = text;
                word.start = _wordStart;
                word.end = _wordEnd;
                [_words addObject:word];
            }
            _word = nil;
            _wordDepth = 0;
        }
        if (_spanDepth) _spanDepth--;
        return;
    }
    if ([element isEqualToString:@"text"] && _textKey.length) {
        if (_allowed) {
            SGKaraokeLine *line = [SGKaraokeLine new];
            line.sourceKey = _textKey;
            if (_words.count) {
                line.words = [_words copy];
                line.start = _words.firstObject.start;
                line.end = MAX(_words.lastObject.end, line.start);
            } else {
                NSString *text = [_plain stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (text.length) {
                    SGKaraokeWord *word = [SGKaraokeWord new];
                    word.text = text;
                    line.words = @[word];
                }
            }
            if (line.words.count) {
                if (!_entries[_textKey]) _entries[_textKey] = [NSMutableDictionary dictionary];
                // When automatic language selection sees several tracks, the first matching track
                // is kept. Explicit language selection has already filtered the others out.
                if (!_entries[_textKey][_kind]) _entries[_textKey][_kind] = line;
            }
        }
        _textKey = nil;
        return;
    }
    if (([element isEqualToString:@"translation"] || [element isEqualToString:@"transliteration"]) && _kind.length) {
        _kind = nil;
        _language = nil;
        _allowed = NO;
    }
}

@end

static NSString *lineText(SGKaraokeLine *line) {
    return line ? SGKaraokeLineText(line) : @"";
}

static SGKaraokeLine *plainAuxLine(NSString *text, SGKaraokeLine *main) {
    if (!text.length) return nil;
    SGKaraokeWord *word = [SGKaraokeWord new];
    word.text = text;
    word.start = main.start;
    word.end = main.end;
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = @[word];
    line.start = main.start;
    line.end = main.end;
    return line;
}

static void attachAuxiliary(NSArray<SGKaraokeLine *> *lines, NSString *xml) {
    NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    SGTTMLAuxReader *reader = [SGTTMLAuxReader new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = reader;
    parser.shouldProcessNamespaces = NO;
    [parser parse];
    for (SGKaraokeLine *line in lines) {
        NSDictionary<NSString *, SGKaraokeLine *> *found = line.sourceKey.length ? reader.entries[line.sourceKey] : nil;
        SGKaraokeLine *translation = found[@"translation"], *pronunciation = found[@"pronunciation"];
        if (translation) {
            if (!translation.words.firstObject.start && !translation.words.firstObject.end) {
                translation = plainAuxLine(lineText(translation), line);
            }
            line.translationLine = translation;
            line.translationText = lineText(translation);
        }
        if (pronunciation) {
            if (!pronunciation.words.firstObject.start && !pronunciation.words.firstObject.end) {
                pronunciation = plainAuxLine(lineText(pronunciation), line);
            }
            line.pronunciationLine = pronunciation;
            line.pronunciationText = lineText(pronunciation);
        }
    }
}

NSArray<SGKaraokeLine *> *SGTTMLLines(NSString *xml) {
    if (![xml isKindOfClass:NSString.class] || !xml.length) return nil;
    NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    SGTTMLReader *reader = [SGTTMLReader new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = reader;
    // The TTML namespaces carry nothing the reader needs, and the prefixes it matches on
    // ("ttm:agent") only survive while they are left alone.
    parser.shouldProcessNamespaces = NO;
    [parser parse];
    if (!reader.lines.count) return nil;
    NSMutableArray<SGKaraokeLine *> *withBreaks = [NSMutableArray array];
    SGKaraokeLine *last = nil;
    for (SGKaraokeLine *line in reader.lines) {
        if (last && line.start - last.end >= 3000) {
            SGKaraokeLine *breakLine = [SGKaraokeLine new];
            breakLine.breakLine = YES;
            breakLine.words = @[];
            breakLine.start = last.end;
            breakLine.end = line.start;
            [withBreaks addObject:breakLine];
        }
        [withBreaks addObject:line];
        last = line;
    }
    SGKaraokeAlignVoices(withBreaks);
    attachAuxiliary(withBreaks, xml);
    return withBreaks;
}
