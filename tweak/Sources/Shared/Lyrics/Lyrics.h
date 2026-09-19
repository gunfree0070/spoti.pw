// The lyrics engine: timed lines and the player's clock, for the redesign's Apple Music style lyrics
// (Redesigned/Lyrics/SGRKaraokeView.h) and the lock screen (Shared/LockScreenLyrics). Spotify only
// times whole lines, so the words inside a line are timed by an estimate (KaraokeTiming.m), unless a
// source of the mod's times them. The lines are read from the color-lyrics response as it arrives, or
// handed over by Shared/LyricsSources, and the position from the player's state (KaraokeSource.x).
#import <UIKit/UIKit.h>

@class SGModRow, SGModSection;
// LyricsSettings.m: the Lyrics page's parts (App/Pages.m puts the page together): where lyrics come
// from, naming the source (read by the redesign's lyrics view only), and the lock screen.
SGModSection *SGLyricsSourcesSection(BOOL namingSource);
SGModRow *SGLockScreenLyricsRow(void);

// Which edge a line is laid against. Apple Music puts a duet's second voice against the far one, so
// the two sides of the song read apart; a track sung by one voice stays leading throughout.
typedef NS_ENUM(NSUInteger, SGKaraokeAlign) {
    SGKaraokeAlignLeading = 0,
    SGKaraokeAlignTrailing,
};

// Times in milliseconds from the start of the track.
@interface SGKaraokeWord : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSInteger start, end;
// Set when nothing separates the word from the one before it, as between Japanese, Chinese or Korean
// syllables: the line lays it flush instead of leaving a space for a word break that is not there.
@property (nonatomic) BOOL joined;
@end

@interface SGKaraokeLine : NSObject
@property (nonatomic, copy) NSArray<SGKaraokeWord *> *words;
@property (nonatomic) NSInteger start, end;
// A timed instrumental/break section. It has no words, but remains in the timeline so the
// redesigned view can show its animated dots for the whole pause instead of holding the last line.
@property (nonatomic) BOOL breakLine;
// The voice singing the line, named as the source names it ("v1", "v2"), nil when it names none.
// SGKaraokeAlignVoices turns these into alignments; nothing else reads it.
@property (nonatomic, copy) NSString *voice;
@property (nonatomic) SGKaraokeAlign align;
// The (oh, aye) sung under the line, smaller and dimmer, nil for nearly every line. Its words are
// timed like any other and it is lit by the same sweep, a beat behind the line it hangs off.
@property (nonatomic, strong) SGKaraokeLine *backing;
// Optional parallel text carried by Apple-style TTML sources. It is kept separate from the sung
// words so a translation or a romanization never contaminates the karaoke sweep.
@property (nonatomic, copy) NSString *translationText;
@property (nonatomic, copy) NSString *pronunciationText;
@end

// The line as one string, a space between the words that are not joined.
NSString *SGKaraokeLineText(SGKaraokeLine *line);
// Whether the text is written in a script that does not space its words, so the pieces of a line
// are words in their own right rather than halves of one.
BOOL SGKaraokeUnspacedScript(NSString *text);
// Gives every line the alignment its voice earns: the voice heard first leads, the next one to be
// named trails, and any after that lead again. A track naming one voice or none is left alone.
void SGKaraokeAlignVoices(NSArray<SGKaraokeLine *> *lines);

// A color-lyrics body, protobuf or JSON, as timed lines; nil unless Spotify synced it by line.
NSArray<SGKaraokeLine *> *SGKaraokeLinesFromBody(NSData *body);
// Lines timed only by their starts, the words inside them estimated; a ♪ or empty text is a break.
NSArray<SGKaraokeLine *> *SGKaraokeEstimatedLines(NSArray<NSNumber *> *starts, NSArray<NSString *> *texts);

NSArray<SGKaraokeLine *> *SGKaraokeLinesForTrack(NSString *trackID);   // nil until the lyrics came
void SGKaraokeKeepLines(NSString *trackID, NSArray<SGKaraokeLine *> *lines);
// Asks spclient for a track's lyrics once, with the headers of Spotify's own requests, for when no
// page of Spotify's has asked for them, e.g. with the app in the background.
void SGKaraokeRequestLyrics(NSString *trackID);
NSString *SGKaraokePlayingTrack(void);   // the base62 id, nil before the player reported
NSInteger SGKaraokePositionMs(void);     // negative when unknown
void SGKaraokeSeek(NSInteger ms);
id SGKaraokePlayer(void);                // SPTEsperantoPlayer, nil before the app asked it for its state
// A track the player has reported, by its base62 id; nil for one it has not played this session.
@class SPTPlayerTrack;
SPTPlayerTrack *SGKaraokeTrackFor(NSString *trackID);
// Keeps a track seen elsewhere, so a source can name it before the player has reported it.
void SGKaraokeRememberTrack(SPTPlayerTrack *track);
