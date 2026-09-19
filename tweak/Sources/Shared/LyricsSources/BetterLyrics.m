// Better Lyrics' public API returns the same Apple-style TTML format used by the other word-timed
// sources, but unlike the older endpoint it carries the optional translations and transliterations
// in <head>. Keeping it as its own provider makes the Apple Music-like buttons useful in practice.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kAPI = @"https://lyrics-api.boidu.dev/getLyrics";

SGLyricsAsk SGBetterLyricsAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length || !query.artist.length) {
        SGLog(@"betterlyrics: nothing to search with for %@", query.trackID);
        done(nil);
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *params = [NSMutableDictionary dictionaryWithDictionary:@{
        @"s": query.title,
        @"a": query.artist,
    }];
    if (query.seconds > 0) params[@"d"] = @(query.seconds).stringValue;
    if (query.album.length) params[@"al"] = query.album;
    SGLyricsGetJSON(SGLyricsURL(kAPI, params), nil, ^(id root) {
        NSString *xml = [root isKindOfClass:NSDictionary.class] ? root[@"ttml"] : nil;
        if (![xml isKindOfClass:NSString.class] || !xml.length) {
            SGLog(@"betterlyrics: no TTML for %@ by %@", query.title, query.artist);
            done(nil);
            return;
        }
        NSArray<SGKaraokeLine *> *lines = SGTTMLLines(xml);
        if (!lines.count) {
            SGLog(@"betterlyrics: the API returned no readable lines for %@ by %@", query.title, query.artist);
            done(nil);
            return;
        }
        SGLyricsResult *result = [SGLyricsResult new];
        result.synced = YES;
        result.wordTimed = YES;
        result.karaokeLines = lines;
        NSArray<NSNumber *> *starts;
        NSArray<NSString *> *texts;
        SGLyricsPageLines(lines, &starts, &texts);
        result.starts = starts;
        result.texts = texts;
        SGLog(@"betterlyrics: %@ by %@ has %lu word-timed lines", query.title, query.artist,
              (unsigned long)lines.count);
        done(result);
    });
};
