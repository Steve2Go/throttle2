//
//  AirPlayHelper.h
//  Throttle 2
//
//  Created by Stephen Grigg on 7/4/2025.
//


#import <UIKit/UIKit.h>

@interface AirPlayHelper : NSObject

+ (void)presentAirPlayPopoverFromBarButtonItem:(UIBarButtonItem *)sender inViewController:(UIViewController *)viewController;

@end