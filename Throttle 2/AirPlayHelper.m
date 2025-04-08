//
//  AirPlayHelper 2.h
//  Throttle 2
//
//  Created by Stephen Grigg on 7/4/2025.
//


#import "AirPlayHelper.h"
#import <MediaPlayer/MediaPlayer.h>

@interface AirPlayHelper () <MPAudioVideoRoutingPopoverControllerDelegate>
@property (nonatomic, strong) id airplayPopoverController;
@end

@implementation AirPlayHelper

+ (instancetype)sharedHelper {
    static AirPlayHelper *helper = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        helper = [[AirPlayHelper alloc] init];
    });
    return helper;
}

+ (void)presentAirPlayPopoverFromBarButtonItem:(UIBarButtonItem *)sender inViewController:(UIViewController *)viewController {
    AirPlayHelper *helper = [AirPlayHelper sharedHelper];
    Class popoverClass = NSClassFromString(@"MPAudioVideoRoutingPopoverController");
    if (popoverClass) {
        helper.airplayPopoverController = [[popoverClass alloc] initWithType:0 includeMirroring:YES];
        if ([helper.airplayPopoverController respondsToSelector:@selector(setDelegate:)]) {
            [helper.airplayPopoverController setDelegate:helper];
        }
        if ([helper.airplayPopoverController respondsToSelector:@selector(presentPopoverFromBarButtonItem:permittedArrowDirections:animated:)]) {
            [helper.airplayPopoverController presentPopoverFromBarButtonItem:sender permittedArrowDirections:UIPopoverArrowDirectionUp animated:YES];
        }
    }
}

// Implement delegate methods if needed

@end