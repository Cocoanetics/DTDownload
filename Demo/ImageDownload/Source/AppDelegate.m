//
//  AppDelegate.m
//  ImageDownloadSample
//
//  Created by Stefan Gugarel on 7/11/13.
//  Copyright (c) 2013 Drobnik KG. All rights reserved.
//

#import "AppDelegate.h"

#import "DTDownloadCache.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	
	[DTDownloadCache sharedInstance].maxNumberOfConcurrentDownloads = 1;
	
	NSURL *URL1 = [NSURL URLWithString:@"http://files.parsetfss.com/fa80bc63-88d4-412d-a478-2451cffc92a8/tfss-f9d777b8-47ae-430f-811b-6855e372c5c4-Proof_012_v1_r1.jpg"];
	NSURL *URL2 = [NSURL URLWithString:@"http://files.parsetfss.com/fa80bc63-88d4-412d-a478-2451cffc92a8/tfss-d1ab483e-48fa-4220-911d-c1cef27d14cb-Proof_010_v1_r1.jpg"];
	NSURL *URL3 = [NSURL URLWithString:@"http://files.parsetfss.com/fa80bc63-88d4-412d-a478-2451cffc92a8/tfss-1c8fe9a8-bec4-4e51-9b5a-30086a2787f6-Proof_011_v1_r1.jpg"];
	NSURL *URL4 = [NSURL URLWithString:@"http://files.parsetfss.com/fa80bc63-88d4-412d-a478-2451cffc92a8/tfss-eb49f6d0-0778-4707-82db-fadbe46aaf10-Proof_009_v1_r1.jpg"];
	
	
	[self _addDownloadForURL:URL1 page:@"Proof_012_v1_r1.jpg"];
	
	[self _addDownloadForURL:URL2 page:@"Proof_010_v1_r1.jpg"];
	
	[self _addDownloadForURL:URL3 page:@"Proof_011_v1_r1.jpg"];
	
	[self _addDownloadForURL:URL4  page:@"Proof_009_v1_r1.jpg"];
	
	
	[[DTDownloadCache sharedInstance] cancelDownloadForURL:URL1];
	[[DTDownloadCache sharedInstance] cancelDownloadForURL:URL2];
	[[DTDownloadCache sharedInstance] cancelDownloadForURL:URL3];

	
	
	
    // Override point for customization after application launch.
    return YES;
}


- (void)_addDownloadForURL:(NSURL *)URL page:(NSString *)page {
	
	[[DTDownloadCache sharedInstance] cachedDataForURL:URL option:DTDownloadCacheOptionReturnCacheAndLoadAlways completion:^(NSURL *URL, NSData *data, NSError *error) {
		
		NSLog(@"Page %@ done", page);
		
	}];
	
}
							
- (void)applicationWillResignActive:(UIApplication *)application
{
	// Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
	// Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	// Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
	// If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
	// Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	// Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	// Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

@end
