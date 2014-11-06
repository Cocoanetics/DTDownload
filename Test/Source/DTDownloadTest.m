//
// Created by rene on 09.01.13.
//
//


#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>
#import "DTDownload.h"
#import "OHHTTPStubs.h"



@interface DTDownloadTest : XCTestCase
@end


@interface DTDownload()
- (NSString *)uniqueFileNameForFile:(NSString *)fileName atDestinationPath:(NSString *)path;
- (NSString *)createBundleFilePathForFilename:(NSString *)fileName;
@end



@implementation DTDownloadTest {
	//NSBundle *bundle;
	DTDownload *download;
	NSString *documentsPath;
	NSFileManager *fileManager;
}

- (void)setUp {
	//bundle = [NSBundle bundleForClass:[self class]];
	
	documentsPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DTDownloadTest"];
	fileManager = [NSFileManager defaultManager];
	
	[fileManager createDirectoryAtPath:documentsPath withIntermediateDirectories:YES attributes:nil error:nil];
	
}

- (void)tearDown {
	[fileManager removeItemAtPath:documentsPath error:nil];
}

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
	// try to create a parser with nil data
	NSURL *URL = [NSURL URLWithString:@"http://localhost/Test2.txt"];
	download = [DTDownload downloadForURL:URL atPath:documentsPath];
	// make sure that this is nil
	XCTAssertNotNil(download, @"download Object should be nil");
	XCTAssertEqualObjects([download.URL description], @"http://localhost/Test2.txt", @"download url is not http://localhost/Test2.txt: %@", download.URL);

	XCTAssertFalse([download canResume], @"The downlaod should be resumable but is not");
}

- (void)testDownloadWithBundle_butNoBundleFound
{
	// try to create a parser with nil data
	NSURL *URL = [NSURL URLWithString:@"http://localhost/Test3.txt"];
	download = [DTDownload downloadForURL:URL atPath:documentsPath];
	// make sure that this is nil
	XCTAssertNotNil(download, @"download Object should be nil");
	XCTAssertEqualObjects([download.URL description], @"http://localhost/Test3.txt", @"download url is not http://localhost/Test3.txt: %@", download.URL);

	XCTAssertFalse([download canResume], @"The downlaod should be resumable but is not");
}


- (void)testUniqueFileNameForFile
{

	download = [[DTDownload alloc] initWithURL:nil withDestinationPath:documentsPath];

	NSString *path = [documentsPath stringByAppendingPathComponent:@"Test1.txt"];

	[@"dummy" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

	NSString *result = [[download uniqueFileNameForFile:@"Test1.txt" atDestinationPath:documentsPath] lastPathComponent];

	XCTAssertEqualObjects(result, @"Test1-1.txt", @"Result should be Test1-1.txt but was: %@", result);
	[[NSFileManager defaultManager] removeItemAtPath:path error:nil];

}

- (void)testUniqueFileNameForFile_more
{
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
  NSString *downloadPath = [bundle resourcePath];

	download = [[DTDownload alloc] initWithURL:nil withDestinationPath:downloadPath];
	NSString *result = [[download uniqueFileNameForFile:@"Test" atDestinationPath:downloadPath] lastPathComponent];

	XCTAssertEqualObjects(result, @"Test-1", @"Result should be Test-1 but was: %@", result);
}


- (void)testCreateDestinationFile
{
	download = [[DTDownload alloc] initWithURL:nil withDestinationPath:documentsPath];
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

	download = [[DTDownload alloc] initWithURL:nil withDestinationFile: [documentsPath stringByAppendingPathComponent:@"MyFileName.txt"]];
	NSString *result = [download createBundleFilePathForFilename:@"Foobar"];


	NSArray *pathComponents = [result pathComponents];

	XCTAssertEqualObjects([pathComponents lastObject], @"MyFileName.txt", @"Result should be MyFileName.txt but was: %@", [pathComponents lastObject]);

	NSString *bundleName = [pathComponents objectAtIndex:[pathComponents count] - 2];
	XCTAssertEqualObjects(bundleName, @"MyFileName.txt.download", @"bundle name should be MyFileName.txt.download but was: %@", bundleName);

	[[NSFileManager defaultManager] removeItemAtPath:result error:nil];
	[[NSFileManager defaultManager] removeItemAtPath:[result stringByDeletingLastPathComponent] error:nil];

}

- (void)downloadWithHeaders:(NSDictionary *)headers {

	NSURL *URL = [NSURL URLWithString:@"http://localhost/path/service?docGuid=&page=1"];
	download = [DTDownload downloadForURL:URL atPath:documentsPath];

	__block BOOL responseArrived = NO;
	[OHHTTPStubs removeAllStubs];
	[OHHTTPStubs stubRequestsPassingTest:^BOOL(NSURLRequest *request) {
			responseArrived = YES;
			return [request.URL.host isEqualToString:@"localhost"];
	}                   withStubResponse:^OHHTTPStubsResponse *(NSURLRequest *request) {
			NSLog(@"headers: %@", headers);
			return [OHHTTPStubsResponse responseWithData:nil statusCode:200 headers:headers];
	}];

	[download start];

	NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
	while (([timeoutDate timeIntervalSinceNow] > 0)) {
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, YES);
		if (responseArrived) {
			break;
		}
	}

}

- (void)testContentDisposition {
	[self downloadWithHeaders:@{@"Content-disposition" : @"attachment; filename=\"TestFileName.png\""}];
	NSString *destinationBundleFilePath = [download valueForKey:@"_destinationBundleFilePath"];
	XCTAssertEqualObjects([destinationBundleFilePath lastPathComponent], @"TestFileName.png", @"Result should be TestFileName.png but was: %@", [destinationBundleFilePath lastPathComponent]);

}

- (void)testContentDisposition_1 {
	[self downloadWithHeaders:@{@"Content-Disposition" : @"attachment; filename=\"TestFileName1.png\""}];
	NSString *destinationBundleFilePath = [download valueForKey:@"_destinationBundleFilePath"];
	XCTAssertEqualObjects([destinationBundleFilePath lastPathComponent], @"TestFileName1.png", @"Result should be TestFileName.png but was: %@", [destinationBundleFilePath lastPathComponent]);
}

- (void)testContentDisposition_2 {
	[self downloadWithHeaders:@{@"content-disposition" : @"attachment; filename=\"TestFileName2.png\""}];
	NSString *destinationBundleFilePath = [download valueForKey:@"_destinationBundleFilePath"];
	XCTAssertEqualObjects([destinationBundleFilePath lastPathComponent], @"TestFileName2.png", @"Result should be TestFileName.png but was: %@", [destinationBundleFilePath lastPathComponent]);
}

- (void)testUnknownFileName {
	[self downloadWithHeaders:nil];
	NSString *destinationBundleFilePath = [download valueForKey:@"_destinationBundleFilePath"];
	XCTAssertEqualObjects([destinationBundleFilePath lastPathComponent], @"unknown", @"Result should be TestFileName.png but was: %@", [destinationBundleFilePath lastPathComponent]);
}

- (void)testDestinationFilePathIsDirectory {
	
	download = [[DTDownload alloc] initWithURL:nil withDestinationFile:documentsPath];

	NSString *result = [download createBundleFilePathForFilename:@"dummy"];
	
	NSArray *pathComponents = [result pathComponents];
	
	XCTAssertEqualObjects([pathComponents lastObject], @"dummy", @"Result should be unknown but was: %@", [pathComponents lastObject]);

	
}

@end