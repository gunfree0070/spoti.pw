#import "Lyrics.h"
#import "Shared/AdBlock/Protobuf.h"

@implementation SGKaraokeWord
@end

@implementation SGKaraokeLine
@end

// A line is sung at about this pace and never takes longer than the gap to the next one. A slow
// line gets at least 60 % of its gap, but not more than 1.8x the estimate, so a long instrumental
// after it does not stretch its last word across the break.
static const NSInteger kLineBaseMs = 350, kMsPerLetter = 75;
static const double kMinGapShare = 0.6, kMaxStretch = 1.8;
// Added to every word's letters, for the breath between words and so a one-letter word still shows.
static const NSUInteger kWordWeight = 2;
// A syllable of an unspaced script is one character but a whole beat, so it counts for this many
// letters; without it a Japanese line reads as a handful of letters and its sweep finishes early.
static const NSUInteger kSyllableLetters = 3;

#pragma mark - the model

NSString *SGKaraokeLineText(SGKaraokeLine *line) {
    if (line.breakLine) return @"♪";
    NSMutableString *text = [NSMutableString string];
    for (SGKaraokeWord *word in line.words) {
        if (text.length && !word.joined) [text appendString:@" "];
        [text appendString:word.text ?: @""];
    }
    return text;
}

// Japanese, Chinese and Korean, and the punctuation set with them. Kana and Hangul are listed as
// well as the ideographs: a line of either is written without spaces just the same.
static NSCharacterSet *unspacedScript(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *building = [NSMutableCharacterSet new];
        [building addCharactersInRange:NSMakeRange(0x3000, 0x40)];    // CJK punctuation
        [building addCharactersInRange:NSMakeRange(0x3040, 0xC0)];    // hiragana and katakana
        [building addCharactersInRange:NSMakeRange(0x3400, 0x9C0)];   // ideographs, extension A
        [building addCharactersInRange:NSMakeRange(0x4E00, 0x5200)];  // ideographs
        [building addCharactersInRange:NSMakeRange(0xAC00, 0x2BA4)];  // hangul syllables
        [building addCharactersInRange:NSMakeRange(0xF900, 0x200)];   // compatibility ideographs
        [building addCharactersInRange:NSMakeRange(0xFF66, 0x38)];    // halfwidth katakana
        set = [building copy];
    });
    return set;
}

BOOL SGKaraokeUnspacedScript(NSString *text) {
    return text.length && [text rangeOfCharacterFromSet:unspacedScript()].location != NSNotFound;
}

void SGKaraokeAlignVoices(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray<NSString *> *heard = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) {
        if (!line.voice.length || [heard containsObject:line.voice]) continue;
        [heard addObject:line.voice];
    }
    if (heard.count < 2) return;   // one voice, or none named: every line leads, as it already does
    NSString *trailing = heard[1];
    for (SGKaraokeLine *line in lines) {
        line.align = [line.voice isEqualToString:trailing] ? SGKaraokeAlignTrailing : SGKaraokeAlignLeading;
        line.backing.align = line.align;
    }
}

#pragma mark - estimating the words inside a line

static NSUInteger lettersIn(NSString *text) {
    __block NSUInteger count = 0;
    NSCharacterSet *letters = NSCharacterSet.alphanumericCharacterSet, *unspaced = unspacedScript();
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *piece, NSRange a, NSRange b, BOOL *stop) {
        if ([unspaced characterIsMember:[piece characterAtIndex:0]]) count += kSyllableLetters;
        else if ([letters characterIsMember:[piece characterAtIndex:0]]) count++;
    }];
    return count;
}

static void appendPiece(NSMutableArray<SGKaraokeWord *> *pieces, NSString *text) {
    if (!text.length) return;
    SGKaraokeWord *word = [SGKaraokeWord new];
    word.text = text;
    [pieces addObject:word];
}

// The line split into what the sweep lights one at a time: words where the script spaces them, a
// syllable at a time where it does not, so a Japanese line sweeps instead of lighting up whole.
// Everything a token holds past its first piece is joined to the one before it.
static NSArray<SGKaraokeWord *> *piecesOf(NSString *line) {
    NSMutableArray<SGKaraokeWord *> *pieces = [NSMutableArray array];
    for (NSString *token in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (!token.length) continue;
        NSUInteger first = pieces.count;
        if (!SGKaraokeUnspacedScript(token)) {
            appendPiece(pieces, token);
        } else {
            // Latin letters or digits caught between two syllables stay together as one piece.
            NSMutableString *run = [NSMutableString string];
            NSCharacterSet *unspaced = unspacedScript();
            [token enumerateSubstringsInRange:NSMakeRange(0, token.length)
                                      options:NSStringEnumerationByComposedCharacterSequences
                                   usingBlock:^(NSString *piece, NSRange a, NSRange b, BOOL *stop) {
                if (![unspaced characterIsMember:[piece characterAtIndex:0]]) {
                    [run appendString:piece];
                    return;
                }
                appendPiece(pieces, [run copy]);
                [run setString:@""];
                appendPiece(pieces, piece);
            }];
            appendPiece(pieces, [run copy]);
        }
        for (NSUInteger i = first + 1; i < pieces.count; i++) pieces[i].joined = YES;
    }
    return pieces;
}

static BOOL isBreak(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length == 0 || [trimmed isEqualToString:@"♪"];
}

// gap is the time to the next line, 0 for the last one.
static SGKaraokeLine *timedLine(NSString *text, NSInteger start, NSInteger gap) {
    NSArray<SGKaraokeWord *> *words = piecesOf(text);
    NSUInteger weight = 0, letters = 0;
    for (SGKaraokeWord *word in words) {
        NSUInteger count = lettersIn(word.text);
        letters += count;
        weight += count + kWordWeight;
    }
    NSInteger estimate = kLineBaseMs + (NSInteger)letters * kMsPerLetter;
    NSInteger sung = estimate;
    if (gap > 0) {
        sung = MAX((NSInteger)(gap * kMinGapShare), estimate);
        sung = MIN(sung, (NSInteger)(estimate * kMaxStretch));
        sung = MIN(sung, gap);
    }

    double at = start;
    for (SGKaraokeWord *word in words) {
        word.start = (NSInteger)at;
        at += weight ? (double)sung * (lettersIn(word.text) + kWordWeight) / weight : 0;
        word.end = (NSInteger)at;
    }
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = start;
    line.end = start + sung;
    return line;
}

NSArray<SGKaraokeLine *> *SGKaraokeEstimatedLines(NSArray<NSNumber *> *starts, NSArray<NSString *> *texts) {
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < texts.count; i++) {
        if (i >= starts.count) break;
        NSInteger start = starts[i].integerValue;
        NSInteger gap = i + 1 < starts.count ? starts[i + 1].integerValue - start : 0;
        if (isBreak(texts[i])) {
            // Keep the pause in the same timed stream. The final break has no next line to bound it,
            // so three seconds is the same fallback used by the source merger for a long gap.
            SGKaraokeLine *breakLine = [SGKaraokeLine new];
            breakLine.breakLine = YES;
            breakLine.words = @[];
            breakLine.start = start;
            breakLine.end = start + (gap > 0 ? gap : 3000);
            [lines addObject:breakLine];
            continue;
        }
        [lines addObject:timedLine(texts[i], start, MAX(gap, 0))];
    }
    return lines.count ? lines : nil;
}

#pragma mark - Spotify's own bodies

// Lyrics { 1 data: { 1 time_synchronized, 2 repeated line: { 1 offset_ms, 2 content } }, 2 colors }
static NSArray<SGKaraokeLine *> *fromProtobuf(NSData *body) {
    SGPBField *data = SGPBFirst(SGPBParse(body), 1);
    if (data.wire != 2) return nil;
    NSArray<SGPBField *> *fields = SGPBParse(data.payload);
    if (!SGPBFirst(fields, 1).varint) return nil;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (SGPBField *field in fields) {
        if (field.number != 2 || field.wire != 2) continue;
        NSArray<SGPBField *> *line = SGPBParse(field.payload);
        [starts addObject:@((int32_t)SGPBFirst(line, 1).varint)];
        [texts addObject:SGPBText(SGPBFirst(line, 2)) ?: @""];
    }
    return SGKaraokeEstimatedLines(starts, texts);
}

// { "lyrics": { "syncType": "LINE_SYNCED", "lines": [ { "startTimeMs": "1234", "words": "..." } ] } }
static NSArray<SGKaraokeLine *> *fromJSON(NSData *body) {
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSDictionary *lyrics = [root isKindOfClass:NSDictionary.class] ? root[@"lyrics"] : nil;
    if (![lyrics isKindOfClass:NSDictionary.class] || ![lyrics[@"syncType"] isEqual:@"LINE_SYNCED"]) return nil;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *line in lyrics[@"lines"]) {
        if (![line isKindOfClass:NSDictionary.class]) continue;
        id words = line[@"words"];
        [starts addObject:@([line[@"startTimeMs"] integerValue])];
        [texts addObject:[words isKindOfClass:NSString.class] ? words : @""];
    }
    return SGKaraokeEstimatedLines(starts, texts);
}

NSArray<SGKaraokeLine *> *SGKaraokeLinesFromBody(NSData *body) {
    if (!body.length) return nil;
    return ((const uint8_t *)body.bytes)[0] == '{' ? fromJSON(body) : fromProtobuf(body);
}
