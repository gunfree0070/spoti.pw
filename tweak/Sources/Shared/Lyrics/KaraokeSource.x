// Where the karaoke page gets its lines and its clock. The color-lyrics body is copied as it passes
// the same URLSession delegates AdBlock/AdNetwork.x reads, untouched, and kept per track, since the
// page may open long after the request finished. The clock is SPTEsperantoPlayer's state, asked for on
// every frame: the player is caught the first time the app asks it, and its position runs on by itself.
// With a source of the mod's on, the color-lyrics body is Shared/LyricsSources' to answer and it
// hands the lines over.
#import "Core/SGCore.h"
#import "Lyrics.h"
#import "Shared/LockScreenLyrics/LockScreenLyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Headers/SPTPlayer.h"
#import <CoreFoundation/CoreFoundation.h>

static const NSUInteger kKeptTracks = 40;
static const NSUInteger kSeenTracks = 200;
// What spclient needs from a request to answer it as the signed-in app.
static NSString *const kSpclientHeaders[] = {@"authorization", @"client-token", @"app-platform", @"spotify-app-version", @"user-agent", @"accept-language"};

static NSMutableDictionary<NSString *, NSArray<SGKaraokeLine *> *> *sg_lyrics;
static NSMutableSet<NSString *> *sg_requested;
static NSDictionary<NSString *, NSString *> *sg_spclientHeaders;
static __weak id sg_player;
// Every track the player has reported, by id, so a source can name a track that is not the one
// playing at the moment it is asked: a lyrics request routinely lands a beat before the player
// moves on to its track. The last object seen is kept by pointer so the check on each call is free,
// and its id behind it, since the player hands out a fresh object with every state it reports.
static NSMutableDictionary<NSString *, SPTPlayerTrack *> *sg_seenTracks;
static __weak SPTPlayerTrack *sg_lastSeen;
static NSString *sg_lastSeenID;   // the player makes a new track object on every state it reports, so the id is what tells a change
static BOOL sg_ownSources;   // a source of the mod's answers the color-lyrics request, not Spotify
static char kBodyKey;
static NSMutableSet<NSString *> *sg_alternateRequests;

NSString *const SGKaraokeLinesDidChangeNotification = @"spotifyglass.karaokeLinesDidChange";

static NSString *const kGoogleTranslateURL = @"https://translate.googleapis.com/translate_a/single";
static NSString *const kAlternateSeparator = @"␟";

static void requestAlternatesOnMain(NSString *trackID, NSArray<SGKaraokeLine *> *lines);

static NSString *trackInURL(NSURL *url) {
    NSString *path = url.path;
    NSRange marker = [path rangeOfString:@"/color-lyrics/v2/track/"];
    if (marker.location == NSNotFound) return nil;
    NSString *track = [[path substringFromIndex:NSMaxRange(marker)] componentsSeparatedByString:@"/"].firstObject;
    return track.length ? track : nil;
}

static void rememberHeaders(NSURLSession *session, NSURLRequest *request) {
    if (![request.URL.host containsString:@"spclient"]) return;
    NSMutableDictionary<NSString *, NSString *> *all = [NSMutableDictionary dictionary];
    [session.configuration.HTTPAdditionalHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class]) all[[key lowercaseString]] = value;
    }];
    [request.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        all[key.lowercaseString] = value;
    }];
    if (!all[@"authorization"]) return;
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < sizeof(kSpclientHeaders) / sizeof(*kSpclientHeaders); i++) {
        NSString *name = kSpclientHeaders[i];
        if (all[name]) headers[name] = all[name];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_spclientHeaders = headers;
        // The player footer can ask for lyrics before Spotify has exposed the headers we need.
        // Retry the current track as soon as the first authenticated request teaches us them;
        // otherwise the lyrics page may stay empty until Spotify happens to request the track again.
        NSString *track = SGKaraokePlayingTrack();
        if (track.length && !sg_lyrics[track]) SGKaraokeRequestLyrics(track);
    });
}

void SGKaraokeKeepLines(NSString *track, NSArray<SGKaraokeLine *> *lines) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_lyrics.count >= kKeptTracks) [sg_lyrics removeAllObjects];
        sg_lyrics[track] = lines;
        // The redesigned player may have laid out its footer before the lyrics request finished.
        // Tell it as soon as the first line set arrives, not only when an optional alternate row
        // is added later.
        [NSNotificationCenter.defaultCenter postNotificationName:SGKaraokeLinesDidChangeNotification object:track];
        requestAlternatesOnMain(track, lines);
    });
}

static void received(NSURLSession *session, NSURLSessionTask *task, NSData *data) {
    rememberHeaders(session, task.currentRequest);
    if (sg_ownSources || !trackInURL(task.currentRequest.URL)) return;
    NSMutableData *body = objc_getAssociatedObject(task, &kBodyKey);
    if (!body) objc_setAssociatedObject(task, &kBodyKey, (body = [NSMutableData data]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [body appendData:data];
}

static void completed(NSURLSessionTask *task, NSError *error) {
    NSMutableData *body = objc_getAssociatedObject(task, &kBodyKey);
    if (!body) {
        NSString *path = task.currentRequest.URL.path;
        if (!sg_ownSources && [path.lowercaseString containsString:@"lyrics"]) SGLog(@"karaoke: lyrics request not read: %@ (error %@)", path, error);
        return;
    }
    objc_setAssociatedObject(task, &kBodyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *track = trackInURL(task.currentRequest.URL);
    if (error || !track) return;
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesFromBody(body);
    SGLog(@"karaoke: lyrics for %@, %lu bytes, %lu synced lines", track, (unsigned long)body.length, (unsigned long)lines.count);
    if (lines) SGKaraokeKeepLines(track, lines);
}

NSArray<SGKaraokeLine *> *SGKaraokeLinesForTrack(NSString *trackID) {
    return trackID ? sg_lyrics[trackID] : nil;
}

static NSString *translationTarget(void) {
    NSArray<NSString *> *codes = @[@"auto", @"ko", @"en", @"ja", @"zh"];
    NSInteger index = [NSUserDefaults.standardUserDefaults integerForKey:SGKeyLyricsTranslationLanguage];
    NSString *selected = index >= 0 && index < (NSInteger)codes.count ? codes[(NSUInteger)index] : @"auto";
    if (![selected isEqualToString:@"auto"]) return selected;
    NSString *preferred = NSLocale.preferredLanguages.firstObject.lowercaseString;
    if ([preferred hasPrefix:@"ko"]) return @"ko";
    if ([preferred hasPrefix:@"ja"]) return @"ja";
    if ([preferred hasPrefix:@"zh"]) return @"zh";
    return @"en";
}

static BOOL needsPronunciation(NSString *text) {
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ((c >= 0x3000 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF)) return YES;
    }
    return NO;
}

static NSString *localPronunciation(NSString *text) {
    CFMutableStringRef mutable = CFStringCreateMutableCopy(NULL, 0, (__bridge CFStringRef)text);
    if (!mutable) return nil;
    CFStringTransform(mutable, NULL, CFSTR("Any-Latin; Latin-ASCII"), false);
    NSString *result = [(__bridge NSString *)mutable copy];
    CFRelease(mutable);
    return [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Google returns translated text in root[0] as small segments. Joining the segments first is
// important: a segment boundary is not always a lyric-line boundary, but our separator survives
// both translation and romanization and lets every result go back to its original line.
static NSString *alternateResponseText(id root, BOOL pronunciation) {
    if (![root isKindOfClass:NSArray.class] || ![(NSArray *)root count]) return nil;
    id rows = [(NSArray *)root firstObject];
    if (![rows isKindOfClass:NSArray.class]) return nil;
    NSUInteger column = pronunciation ? 3 : 0;
    NSMutableString *text = [NSMutableString string];
    for (id row in (NSArray *)rows) {
        if (![row isKindOfClass:NSArray.class] || [(NSArray *)row count] <= column) continue;
        id part = row[column];
        if ([part isKindOfClass:NSString.class]) [text appendString:part];
    }
    return text.length ? text : nil;
}

static NSArray<NSString *> *alternateParts(NSString *text, NSUInteger count) {
    if (!text.length || !count) return nil;
    NSString *clean = [text stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    NSArray<NSString *> *parts = [clean componentsSeparatedByString:kAlternateSeparator];
    if (parts.count < count && count == 1) parts = @[clean];
    if (parts.count < count) return nil;
    NSMutableArray<NSString *> *answer = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *part = [parts[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [answer addObject:part ?: @""];
    }
    return answer;
}

static SGKaraokeLine *alternateLine(NSString *text, SGKaraokeLine *main) {
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

static BOOL attachAlternateParts(NSArray<SGKaraokeLine *> *lines, NSArray<NSString *> *parts,
                                 BOOL pronunciation) {
    if (lines.count != parts.count) return NO;
    BOOL changed = NO;
    for (NSUInteger i = 0; i < lines.count; i++) {
        SGKaraokeLine *line = lines[i];
        NSString *text = parts[i];
        if (!text.length || [text isEqualToString:SGKaraokeLineText(line)]) continue;
        if (pronunciation) {
            if (line.pronunciationText.length) continue;
            line.pronunciationText = text;
            line.pronunciationLine = alternateLine(text, line);
        } else {
            if (line.translationText.length) continue;
            line.translationText = text;
            line.translationLine = alternateLine(text, line);
        }
        changed = YES;
    }
    return changed;
}

static void postAlternateChange(NSString *trackID) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGKaraokeLinesDidChangeNotification object:trackID];
}

static void requestAlternateText(NSString *trackID, NSArray<SGKaraokeLine *> *lines,
                                 NSArray<SGKaraokeLine *> *candidates, BOOL pronunciation) {
    NSMutableArray<NSString *> *source = [NSMutableArray arrayWithCapacity:candidates.count];
    for (SGKaraokeLine *line in candidates) [source addObject:SGKaraokeLineText(line) ?: @""];
    NSString *query = [source componentsJoinedByString:kAlternateSeparator];
    if (!query.length) return;
    NSDictionary<NSString *, NSString *> *params = @{
        @"client": @"gtx",
        @"sl": @"auto",
        @"tl": pronunciation ? @"ja" : translationTarget(),
        @"dt": pronunciation ? @"rm" : @"t",
        @"q": query,
    };
    SGLyricsGetJSON(SGLyricsURL(kGoogleTranslateURL, params), nil, ^(id root) {
        if (sg_lyrics[trackID] != lines) return;
        NSString *response = alternateResponseText(root, pronunciation);
        NSArray<NSString *> *parts = alternateParts(response, candidates.count);
        BOOL changed = parts && attachAlternateParts(candidates, parts, pronunciation);
        // The online romanizer is preferred because it knows Japanese readings of kanji. If it is
        // unavailable, CoreFoundation still provides a useful Latin fallback instead of hiding the
        // pronunciation control completely.
        if (!changed && pronunciation) {
            NSMutableArray<NSString *> *local = [NSMutableArray arrayWithCapacity:candidates.count];
            for (SGKaraokeLine *line in candidates) [local addObject:localPronunciation(SGKaraokeLineText(line)) ?: @""];
            changed = attachAlternateParts(candidates, local, YES);
        }
        if (changed) postAlternateChange(trackID);
    });
}

static void requestAlternatesOnMain(NSString *trackID, NSArray<SGKaraokeLine *> *lines) {
    if (!trackID.length || !lines.count || [sg_alternateRequests containsObject:trackID]) return;
    NSMutableArray<SGKaraokeLine *> *candidates = [NSMutableArray array];
    BOOL needsTranslation = NO, needsRomanization = NO;
    for (SGKaraokeLine *line in lines) {
        NSString *text = SGKaraokeLineText(line);
        if (line.breakLine || !text.length) continue;
        [candidates addObject:line];
        if (!line.translationText.length) needsTranslation = YES;
        if (!line.pronunciationText.length && needsPronunciation(text)) needsRomanization = YES;
    }
    if (!candidates.count || (!needsTranslation && !needsRomanization)) return;
    [sg_alternateRequests addObject:trackID];
    if (needsTranslation) requestAlternateText(trackID, lines, candidates, NO);
    if (needsRomanization) requestAlternateText(trackID, lines, candidates, YES);
}

void SGKaraokeRequestAlternates(NSString *trackID) {
    if (!trackID.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        requestAlternatesOnMain(trackID, sg_lyrics[trackID]);
    });
}

static void requestFromSpotify(NSString *trackID) {
    NSDictionary<NSString *, NSString *> *headers = sg_spclientHeaders;
    if (!headers) return;
    [sg_requested addObject:trackID];
    NSString *address = [NSString stringWithFormat:@"https://spclient.wg.spotify.com/color-lyrics/v2/track/%@?format=json&vocalRemoval=false&market=from_token", trackID];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:name];
    }];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    // The mod's own, so LyricsHook's request hook does not send it to the donor.
    [NSURLProtocol setProperty:@YES forKey:SGLyricsOwnRequestKey inRequest:request];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesFromBody(body);
        SGLog(@"karaoke: fetched lyrics for %@: status %ld, %lu synced lines, error %@", trackID,
              (long)[(NSHTTPURLResponse *)response statusCode], (unsigned long)lines.count, error);
        if (lines) {
            SGKaraokeKeepLines(trackID, lines);
            SGLyricsSetCredit(trackID, @"Spotify");
        }
    }] resume];
}

void SGKaraokeRequestLyrics(NSString *trackID) {
    if (!trackID || sg_lyrics[trackID] || [sg_requested containsObject:trackID]) return;
    if (!sg_ownSources) {
        requestFromSpotify(trackID);
        return;
    }
    [sg_requested addObject:trackID];
    SGLyricsFetch(trackID, ^(SGLyricsResult *lyrics) {
        if (lyrics.karaokeLines) {
            SGKaraokeKeepLines(trackID, lyrics.karaokeLines);
            SGLyricsSetCredit(trackID, lyrics.provider);
            return;
        }
        [sg_requested removeObject:trackID];
        requestFromSpotify(trackID);
    });
}

id SGKaraokePlayer(void) {
    return sg_player;
}

static SPTPlayerState *playerState(void) {
    id player = sg_player;
    return [player respondsToSelector:@selector(state)] ? [(id<SPTPlayer>)player state] : nil;
}

NSString *SGKaraokePlayingTrack(void) {
    id uri = playerState().track.URI;
    NSString *text = [uri isKindOfClass:NSURL.class] ? ((NSURL *)uri).absoluteString : [uri description];
    return [text hasPrefix:@"spotify:track:"] ? [text substringFromIndex:@"spotify:track:".length] : nil;
}

NSInteger SGKaraokePositionMs(void) {
    SPTPlayerState *state = playerState();
    if (!state) return -1;
    return (NSInteger)((state.isPaused ? state.positionAsOfTimestamp : state.position) * 1000);
}

void SGKaraokeSeek(NSInteger ms) {
    id player = sg_player;
    if (![player respondsToSelector:@selector(seekTo:)]) return;
    [(id<SPTPlayer>)player seekTo:ms / 1000.0];
}

static NSString *idOf(SPTPlayerTrack *track) {
    id uri = track.URI;
    NSString *text = [uri isKindOfClass:NSURL.class] ? ((NSURL *)uri).absoluteString : [uri description];
    return [text hasPrefix:@"spotify:track:"] ? [text substringFromIndex:@"spotify:track:".length] : nil;
}

// Tracks come in from the player and from every list that reads their metadata, so when the table
// is full it is emptied, all but the track playing, whose name the next lyrics request needs.
static void remember(SPTPlayerTrack *track, NSString *trackID) {
    @synchronized (sg_seenTracks) {
        if (sg_seenTracks.count >= kSeenTracks) {
            [sg_seenTracks removeAllObjects];
            SPTPlayerTrack *playing = sg_lastSeen;
            NSString *playingID = playing ? idOf(playing) : nil;
            if (playingID) sg_seenTracks[playingID] = playing;
        }
        sg_seenTracks[trackID] = track;
    }
}

SPTPlayerTrack *SGKaraokeTrackFor(NSString *trackID) {
    if (!trackID) return nil;
    @synchronized (sg_seenTracks) { return sg_seenTracks[trackID]; }
}

void SGKaraokeRememberTrack(SPTPlayerTrack *track) {
    if (!sg_seenTracks) return;
    NSString *trackID = idOf(track);
    if (trackID) remember(track, trackID);
}

// With a source of the mod's on, the walk for a track starts the moment the player moves to it and,
// for the track after it, while this one still plays: Spotify asks for a track's lyrics within a
// beat of starting it and gives its card list about a second to load, so an answer that is already
// in is what puts the card there. The track is named here, so no walk waits for a name.
static void prefetch(SPTPlayerTrack *track, NSString *trackID, SPTPlayerState *state) {
    if (!sg_ownSources) return;
    SGLyricsPrefetch(trackID);
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    id next = [future isKindOfClass:NSArray.class] ? [(NSArray *)future firstObject] : nil;
    if (![next isKindOfClass:objc_getClass("SPTPlayerTrack")]) return;
    NSString *nextID = idOf(next);
    if (!nextID || [nextID isEqualToString:trackID]) return;
    remember(next, nextID);
    SGLyricsPrefetch(nextID);
}

%hook SPTEsperantoPlayer
- (id)state {
    if (!sg_player) sg_player = self;
    SPTPlayerState *state = %orig;
    SPTPlayerTrack *track = state.track;
    if (track && track != sg_lastSeen) {
        sg_lastSeen = track;
        NSString *trackID = idOf(track);
        if (trackID && ![trackID isEqualToString:sg_lastSeenID]) {
            sg_lastSeenID = trackID;
            remember(track, trackID);
            prefetch(track, trackID, state);
        }
    }
    return state;
}
%end

%hook SPTDataLoaderService
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    received(session, task, data);
    %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    completed(task, error);
    %orig;
}
%end

%hook _TtC26Connectivity_HttpClientKit20HttpClientURLSession
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    received(session, task, data);
    %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    completed(task, error);
    %orig;
}
%end

%ctor {
    // The sources that search by name learn the name from the player, so the player is caught
    // whenever one is on, not only for the redesign's lyrics and the lock screen.
    if (!SGRedesignedUI() && !SGFlag(SGKeyLockScreenLyrics, NO) && !SGLyricsEnabled()) return;
    sg_seenTracks = [NSMutableDictionary dictionary];
    sg_lyrics = [NSMutableDictionary dictionary];
    sg_requested = [NSMutableSet set];
    sg_alternateRequests = [NSMutableSet set];
    sg_ownSources = SGLyricsEnabled();
    %init;
    SGLog(@"karaoke: on");
    SGRequireClasses(@[
        @"SPTEsperantoPlayer", @"SPTPlayerState",
        @"SPTDataLoaderService", @"_TtC26Connectivity_HttpClientKit20HttpClientURLSession",
    ]);
}
