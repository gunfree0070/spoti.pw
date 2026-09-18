// The Live Activity page, in the redesign only (App/ModSettings.x links it from the root).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "LiveActivity.h"

static NSArray<NSString *> *viewNames(void) {
    return @[@"가사", @"대기열", @"제어 메뉴"];
}

UIViewController *SGRLiveActivitySettingsPage(void) {
    SGModRow *on = SGOptionRow(@"Live Activity", @"On the lock screen and in the Dynamic Island", SGRKeyLiveActivity);
    on.changed = ^(BOOL value) { SGRSetLiveActivityEnabled(value); };
    SGModRow *view = SGChoiceRow(@"Shows", nil, SGRKeyLiveActivityView, viewNames(), SGRLiveActivityLyrics);
    return [[SGModPage alloc] initWithTitle:@"Live Activity" intro:nil sections:@[
        SGSection(nil, @[on, view]),
    ] footer:nil];
}

NSString *SGRLiveActivitySummary(void) {
    if (!SGFlag(SGRKeyLiveActivity, NO)) return @"Off";
    NSInteger index = SGInt(SGRKeyLiveActivityView, SGRLiveActivityLyrics);
    NSArray<NSString *> *names = viewNames();
    return index >= 0 && index < (NSInteger)names.count ? names[index] : names.firstObject;
}
