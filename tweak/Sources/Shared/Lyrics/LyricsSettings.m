// The Lyrics page's parts. The page itself is App/Pages.m's, which adds what only one look has.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Lyrics.h"
#import "Shared/LockScreenLyrics/LockScreenLyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"

SGModSection *SGLyricsSourcesSection(BOOL namingSource) {
    // The row reads the order out, so which sources are on is visible without opening it.
    SGModRow *sources = SGPageRow(@"Lyrics sources", ^UIViewController *{ return SGLyricsSourcesPage(); });
    sources.subtitle = @"BiniLyrics, Musixmatch, Unison, NetEase and LRCLIB, in the order you put them";
    sources.value = ^NSString *{
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *key in SGLyricsOrder()) [names addObject:SGLyricsProviderFor(key).name];
        return names.count ? [names componentsJoinedByString:@", "] : @"Off";
    };
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObjects:sources,
        SGOptionRow(@"Lyrics for every track", @"Offers the lyrics card on tracks Spotify has no lyrics for; needs a source above", SGKeyLyricsAllTracks), nil];
    [rows addObject:SGChoiceRow(@"Translation language", @"Uses a matching translation when a lyrics source provides more than one", SGKeyLyricsTranslationLanguage,
                                @[@"Automatic", @"Korean", @"English", @"Japanese", @"Chinese"], 0)];
    if (namingSource) {
        [rows addObject:SGChoiceRow(@"Lyrics display", @"Choose lyrics, translation and pronunciation/romanization rows", SGKeyLyricsDisplayMode,
                                    @[@"Lyrics only", @"Lyrics + translation + pronunciation", @"Translation only", @"Pronunciation only"], 0)];
        [rows addObject:SGChoiceRow(@"Alternate row order", @"Order the translation and pronunciation rows", SGKeyLyricsDisplayOrder,
                                    @[@"Pronunciation, then translation", @"Translation, then pronunciation"], 0)];
    }
    if (namingSource) [rows addObject:SGOptionRow(@"Name the source", @"Reads out which source the lines on the full screen page came from", SGKeyLyricsCredit)];
    return SGNotedSection(@"Where lyrics come from", rows, @"With no source on, Spotify's own lyrics are left alone.");
}

SGModRow *SGLockScreenLyricsRow(void) {
    return SGOptionRow(@"Replace artist with lyrics", @"The line being sung shows in place of the artist, so lyrics show up on the lock screen and in CarPlay", SGKeyLockScreenLyrics);
}
