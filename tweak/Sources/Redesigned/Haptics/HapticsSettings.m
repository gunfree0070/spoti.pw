// The Vibrations section of the Player page, in the redesign only (App/Pages.m puts it there).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Haptics.h"

static NSString *const kMusicHapticsInfo = @"The iPhone taps along with the drums and rumbles under the bass of whatever Spotify is playing, worked out from the sound as it plays, much like Music Haptics in Apple Music.\n\nIt follows Spotify's own speaker or headphone output, including while the screen is locked. Haptic events are driven at the strongest Core Haptics level; a song playing on another device through Connect has no local sound here to follow.";

SGModSection *SGRVibrationsSection(void) {
    SGModRow *controls = SGSwitchRow(@"Controls", @"Play, pause, skipping, scrubbing, shuffle, repeat and adding a song", SGRKeyControlHaptics);
    SGModRow *music = SGOptionRow(@"Music Haptics", @"Taps and rumbles along with the music", SGRKeyMusicHaptics);
    music.info = kMusicHapticsInfo;
    music.changed = ^(BOOL on) { SGRSetMusicHapticsEnabled(on); };
    return SGSection(@"Vibrations", @[
        SGWithSymbol(controls, @"hand.tap"),
        SGWithSymbol(music, @"waveform"),
    ]);
}
