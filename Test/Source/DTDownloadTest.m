//
// Created by rene on 09.01.13.
//
// To change the template use AppCode | Preferences | File Templates.
//


#import <XCTest/XCTest.h>
#import "DTDownloadTest.h"
#import "DTDownload.h"


@interface DTDownload()
- (NSString *)uniqueFileNameForFile:(NSString *)fileName atDestinationPath:(NSString *)path;
- (NSString *)createBundleFilePathForFilename:(NSString *)fileName;
@end



@implementation DTDownloadTest

- (void)testDownloadWithBundlePath1
{
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];

	// try to create a parser with nil data
	NSURL *URL = [NSURL URLWithString:@"http://localhost/Test1.txt"];
	DTDownload *download = [DTDownload downloadForURL:URL atPath:[bundle bundlePath]];
	// make sure that this is nil
	XCTAssertNotNil(download, @"download Object should be nil");
	XCTAssertEqualObjects([download.URL description], @"http://localhost/Test1.txt", @"download url is not http://localhost/Test1.txt: %@", download.URL);
	XCTAssertTrue([download canResume], @"The downlaod should be resumable but is not");
}

- (void)testDownloadWithBundlePath2
{
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];

	// try to create a parser with nil data
	NSURL *URL = [NSURL URLWithString:@"http://localhost/Test2.txt"];
	DTDownload *download = [DTDownload downloadForURL:URL atPath:[bundle bundlePath]];
	// make sure that this is nil
	XCTAssertNotNil(download, @"download Object should be nil");
	XCTAssertEqualObjects([download.URL description], @"http://localhost/Test2.txt", @"download url is not http://localhost/Test2.txt: %@", download.URL);

	XCTAssertFalse([download canResume], @"The downlaod should be resumable but is not");
}

- (void)testDownloadWithBundle_butNoBundleFound
{
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];

	// try to create a parser with nil data
	NSURL *URL = [NSURL URLWithString:@"http://localhost/Test3.txt"];
	DTDownload *download = [DTDownload downloadForURL:URL atPath:[bundle bundlePath]];
	// make sure that this is nil
	XCTAssertNotNil(download, @"download Object should be nil");
	XCTAssertEqualObjects([download.URL description], @"http://localhost/Test3.txt", @"download url is not http://localhost/Test3.txt: %@", download.URL);

	XCTAssertFalse([download canResume], @"The downlaod should be resumable but is not");
}


- (void)testUniqueFileNameForFile
{
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *downloadPath = [bundle resourcePath];
    
	DTDownload *download = [[DTDownload alloc] initWithURL:nil withDestinationPath:downloadPath];
	NSString *result = [[download uniqueFileNameForFile:@"Test1.txt" atDestinationPath:downloadPath] lastPathComponent];

	XCTAssertEqualObjects(result, @"Test1-1.txt", @"Result should be Test1-1.txt but was: %@", result);
}

- (void)testUniqueFileNameForFile_more
{
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *downloadPath = [bundle resourcePath];

	DTDownload *download = [[DTDownload alloc] initWithURL:nil withDestinationPath:downloadPath];
	NSString *result = [[download uniqueFileNameForFile:@"Test" atDestinationPath:downloadPath] lastPathComponent];

	XCTAssertEqualObjects(result, @"Test-1", @"Result should be Test-1 but was: %@", result);
}


- (void)testCreateDestinationFile
{
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];

	DTDownload *download = [[DTDownload alloc] initWithURL:nil withDestinationPath:[bundle bundlePath]];
	NSString *result = [download createBundleFilePathForFilename:@"Foobar"];


	NSArray *pathComponents = [result pathComponents];


	XCTAssertEqualObjects([pathComponents lastObject], @"Foobar", @"Result should be Foobar but was: %@", [pathComponents lastObject]);

	NSString *bundleName = [pathComponents objectAtIndex:[pathComponents count] - 2];
	XCTAssertEqualObjects(bundleName, @"Foobar.download", @"bundle name should be Foobar.download but was: %@", bundleName);

	// cleanup
	[[NSFileManager defaultManager] removeItemAtPath:result error:nil];
	[[NSFileManager defaultManager] removeItemAtPath:[result stringByDeletingLastPathComponent] error:nil];

}


- (void)testCreateDestinationFileWithGivenFilename
{
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];

	DTDownload *download = [[DTDownload alloc] initWithURL:nil withDestinationFile: [[bundle bundlePath] stringByAppendingPathComponent:@"MyFileName.txt"]];
	NSString *result = [download createBundleFilePathForFilename:@"Foobar"];


	NSArray *pathComponents = [result pathComponents];

	XCTAssertEqualObjects([pathComponents lastObject], @"MyFileName.txt", @"Result should be MyFileName.txt but was: %@", [pathComponents lastObject]);

	NSString *bundleName = [pathComponents objectAtIndex:[pathComponents count] - 2];
	XCTAssertEqualObjects(bundleName, @"MyFileName.txt.download", @"bundle name should be MyFileName.txt.download but was: %@", bundleName);

	[[NSFileManager defaultManager] removeItemAtPath:result error:nil];
	[[NSFileManager defaultManager] removeItemAtPath:[result stringByDeletingLastPathComponent] error:nil];

}

@end