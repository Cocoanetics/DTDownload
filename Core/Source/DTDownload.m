//
//  DTDownload.m
//  DTFoundation
//
//  Created by Oliver Drobnik on 8/6/10.
//  Copyright 2010 Drobnik.com. All rights reserved.
//

#import "DTDownload.h"
#import "DTLog.h"

#define PROGRESS_INTERVAL 0.017

NSString *const DTDownloadDidStartNotification = @"DTDownloadDidStartNotification";
NSString *const DTDownloadDidFinishNotification = @"DTDownloadDidFinishNotification";
NSString *const DTDownloadDidCancelNotification = @"DTDownloadDidCancelNotification";
NSString *const DTDownloadProgressNotification = @"DTDownloadProgressNotification";

static NSString *const DownloadEntryErrorCodeDictionaryKey = @"DownloadEntryErrorCodeDictionaryKey";
static NSString *const DownloadEntryErrorDomainDictionaryKey = @"DownloadEntryErrorDomainDictionaryKey";
static NSString *const DownloadEntryPath = @"DownloadEntryPath";
static NSString *const DownloadEntryProgressBytesSoFar = @"DownloadEntryProgressBytesSoFar";
static NSString *const DownloadEntryProgressTotalToLoad = @"DownloadEntryProgressTotalToLoad";
static NSString *const DownloadEntryResumeInformation = @"DownloadEntryResumeInformation";
static NSString *const DownloadEntryURL = @"DownloadEntryURL";
static NSString *const NSURLDownloadBytesReceived = @"NSURLDownloadBytesReceived";
static NSString *const NSURLDownloadEntityTag = @"NSURLDownloadEntityTag";

@interface DTDownload () <NSURLConnectionDelegate, NSURLSessionDownloadDelegate, NSURLSessionDelegate, NSURLSessionTaskDelegate>

@property(nonatomic, retain) NSDate *lastPacketTimestamp;

- (void)storeDownloadInfo;

- (void)_completeWithSuccess;

- (void)_completeWithError:(NSError *)error;

@end



@implementation DTDownload
{
	NSURL *_URL;
	NSString *_downloadEntityTag;
	NSDate *_lastModifiedDate;
	
	NSString *_destinationPath;
	NSString *_destinationFileName;
	
	// NSURLConnection
	NSURLConnection *_urlConnection;
	NSMutableData *_receivedData;
	
	// NSURLSession
	NSURLSession *_backgroundSession;
	NSURLSessionDownloadTask *_downloadTask;

	NSDate *_lastPacketTimestamp;
	float _previousSpeed;
	
	long long _receivedBytes;
	long long _expectedContentLength;
	long long _resumeFileOffset;
	
	NSData *_resumeData;
	
	NSString *_contentType;
	
	NSString *_destinationBundleFilePath;
	NSFileHandle *_destinationFileHandle;
	
	__unsafe_unretained id <DTDownloadDelegate> _delegate;
	
	BOOL _headOnly;
	
	// response handlers
	DTDownloadResponseHandler _responseHandler;
	DTDownloadCompletionHandler _completionHandler;
	
	NSDate *_lastProgressSentDate;
	
	BOOL _isResume;
	
	BOOL _didReceiveResponse;
	
	NSString *_temporaryDownloadLocationPath;
	
	BOOL _shouldCancel;
}

#pragma mark - Creation

- (id)initWithURL:(NSURL *)URL
{
	return [self initWithURL:URL withDestinationPath:nil];
}

- (id)initWithURL:(NSURL *)URL withDestinationPath:(NSString *)destinationPath;
{
	NSAssert(![URL isFileURL], @"File URL is illegal parameter for DTDownload");
	
	self = [super init];
	if (self)
	{
		_URL = URL;
		_resumeFileOffset = 0;
		_destinationPath = destinationPath;
		_isResume = NO;
#if TARGET_OS_IPHONE
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
#else
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
#endif
		if ([NSURLSession class])
		{
			NSString *URLSessionIdentifier = [NSString stringWithFormat:@"com.cocoanetics.DTDownload.BackgroundSessionConfiguration-%f-%@", [[NSDate date] timeIntervalSince1970], _URL];
			NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfiguration:URLSessionIdentifier];
			_backgroundSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
		}
	}
	return self;
}

- (id)initWithURL:(NSURL *)URL withDestinationFile:(NSString *)destinationFile
{
	self = [self initWithURL:URL withDestinationPath:[destinationFile stringByDeletingLastPathComponent]];
	_destinationFileName = [destinationFile lastPathComponent];
	return self;
}



- (id)initWithDictionary:(NSDictionary *)dictionary atBundlePath:(NSString *)path;
{
	self = [super init];
	if (self)
	{
		[self setInfoDictionary:dictionary];
		
		// update the destination path so that the path is correct also if the download bundle was moved
		_destinationBundleFilePath = [path stringByAppendingPathComponent:[_destinationBundleFilePath lastPathComponent]];
		
		NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_destinationBundleFilePath error:nil];
		NSNumber *fileSize = [fileAttributes objectForKey:NSFileSize];
		if ([fileSize longLongValue] < _resumeFileOffset) {
			_resumeFileOffset = 0;
		}
		_isResume = NO;
		
		if ([NSURLSession class])
		{
			NSString *URLSessionIdentifier = [NSString stringWithFormat:@"com.cocoanetics.DTDownload.BackgroundSessionConfiguration-%f-%@", [[NSDate date] timeIntervalSince1970], _URL];
			NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfiguration:URLSessionIdentifier];
			_backgroundSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
		}
		
#if TARGET_OS_IPHONE
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
#else
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
#endif
	}
	return self;
}

- (id)initWithResumeData:(NSData *)resumeData atPath:(NSString *)path URL:(NSURL *)URL
{
	self = [super init];
	if (self)
	{
		_destinationBundleFilePath = path;
		_resumeData = resumeData;
		_URL = URL;
		
		_isResume = YES;
		
		if ([NSURLSession class])
		{
			NSString *URLSessionIdentifier = [NSString stringWithFormat:@"com.cocoanetics.DTDownload.BackgroundSessionConfiguration-%f-%@", [[NSDate date] timeIntervalSince1970], _URL];
			NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfiguration:URLSessionIdentifier];
			_backgroundSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
		}
		
#if TARGET_OS_IPHONE
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
#else
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
#endif
	}
	return self;
}


+ (DTDownload *)downloadForURL:(NSURL *)URL atPath:(NSString *)path
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:path];
	NSString *file;
	while (file = [enumerator nextObject])
	{
		if ([[file pathExtension] isEqualToString:@"download"])
		{
			NSString *bundlePath = [path stringByAppendingPathComponent:file];
			NSString *infoFile = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
			NSString *resumeDataPath = [bundlePath stringByAppendingPathComponent:@"resumedata"];
			
			NSFileManager *fileManager = [NSFileManager defaultManager];
			
			if ([fileManager fileExistsAtPath:infoFile isDirectory:nil])
			{
				NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfFile:infoFile];
				
				if (dictionary)
				{
					NSString *infoFileURL = [dictionary objectForKey:DownloadEntryURL];
					if ([infoFileURL isEqualToString:[URL absoluteString]])
					{
						return [[DTDownload alloc] initWithDictionary:dictionary atBundlePath:bundlePath];
					}
				}
			}
			else if ([fileManager fileExistsAtPath:resumeDataPath isDirectory:nil])
			{
				NSData *resumeData = [NSData dataWithContentsOfFile:resumeDataPath];
				
				NSString *fileName = [file stringByDeletingPathExtension];
				NSString *downloadFilePath = [bundlePath stringByAppendingPathComponent:fileName];
				
				if (resumeData && [[URL lastPathComponent] isEqualToString:fileName])
				{
					return [[DTDownload alloc] initWithResumeData:resumeData atPath:downloadFilePath URL:URL];
				}
			}
				
		}
	}
	return [[DTDownload alloc] initWithURL:URL withDestinationPath:path];
}


- (void)dealloc
{
	DTLogDebug(@"DEALLOC of DTDownload for URL: %@", _URL);
	
	_urlConnection = nil;
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[self closeDestinationFile];
	// stop connection if still in flight
	[self stop];
}

#pragma mark - Downloading

- (void)startHEAD
{
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_URL
																			 cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
																		timeoutInterval:60.0];
	[request setHTTPMethod:@"HEAD"];
	
	
	if ([NSURLSession class])
	{
		_downloadTask = [_backgroundSession downloadTaskWithRequest:request];
		
		NSParameterAssert(_downloadTask);
		
		[_downloadTask resume];
	}
	else
	{
		// startNext downloading
		_urlConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
		
		// without this special it would get paused during scrolling of scroll views
		[_urlConnection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		[_urlConnection start];
	}
	
	// getting only a HEAD
	_headOnly = YES;
}


- (void)start
{
	if ([NSURLSession class] && _downloadTask)
	{
		return;
	}
	else if (_urlConnection)
	{
		return;
	}
	
	
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_URL cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData timeoutInterval:60.0];
	
	if (_receivedBytes && _receivedBytes == _expectedContentLength)
	{
		// Already done!
		[self _completeWithSuccess];
		return;
	}
	
	[_additionalHTTPHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		[request setValue:obj forHTTPHeaderField:key];
	}];
	
	if ([NSURLSession class])
	{
		if (_resumeData)
		{
			_downloadTask = [_backgroundSession downloadTaskWithResumeData:_resumeData];
		}
		
		if (!_downloadTask)
		{
			_downloadTask = [_backgroundSession downloadTaskWithRequest:request];
		}
		
		NSParameterAssert(_downloadTask);
		
		[_downloadTask resume];
	}
	else
	{
		if (_resumeFileOffset)
		{
			[request setValue:[NSString stringWithFormat:@"bytes=%lld-", _resumeFileOffset] forHTTPHeaderField:@"Range"];
		}
		
		_urlConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
		
		// without this special it would get paused during scrolling of scroll views
		[_urlConnection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		
		// start urlConnection on the main queue, because when download lots of small file, we had a crash when this is done on a background thread
		dispatch_async(dispatch_get_main_queue(), ^{
			
			[_urlConnection start];
		});
	}
	
	[[NSNotificationCenter defaultCenter] postNotificationName:DTDownloadDidStartNotification object:self];
	
	if (_urlConnection)
	{
		_receivedData = [NSMutableData data];
	}
	
	_lastProgressSentDate = [NSDate date];
}

- (void)stop
{
	[self _stopWithResume:YES];
}

- (void)_stopWithResume:(BOOL)resume
{
	if (!_urlConnection && !_downloadTask)
	{
		return;
	}

	// only send cancel notification if it was loading
	if ([NSURLSession class])
	{
		if (resume)
		{
			[_downloadTask cancelByProducingResumeData:^(NSData *resumeData) {
				
				if (_destinationBundleFilePath)
				{
					// change extension to .resume > for easier identification between DTDownload
					NSString *resumeDataPath = _destinationBundleFilePath;
					resumeDataPath = [resumeDataPath stringByDeletingLastPathComponent];
					resumeDataPath = [resumeDataPath stringByAppendingPathComponent:@"resumedata"];
					
					NSError *error;
					[resumeData writeToFile:resumeDataPath options:NSDataWritingAtomic error:&error];
					
					if (error)
					{
						DTLogError(@"Error when saving data of download for resuming later, %@", error);
					}
				}
				else
				{
					DTLogDebug(@"NO destination bundle path set - not possible to resume download");
				}
				
				_downloadTask = nil;
			}];
		}
		else
		{
			[_downloadTask cancel];
			_downloadTask = nil;
		}
	}
	else
	{
		// update resume info on disk if necessary
		[self storeDownloadInfo];
		_resumeFileOffset = _receivedBytes;
		
		// cancel the connection
		[_urlConnection cancel];
		_urlConnection = nil;
	}
	
	// send notification
	[[NSNotificationCenter defaultCenter] postNotificationName:DTDownloadDidCancelNotification object:self];
	
	if ([_delegate respondsToSelector:@selector(downloadDidCancel:)])
	{
		[_delegate downloadDidCancel:self];
	}
	_receivedData = nil;
	_destinationFileHandle = nil;
}

- (void)cleanup
{
	[self stop];
	
	// remove cached file
	NSFileManager *fileManager = [[NSFileManager alloc] init];
	[fileManager removeItemAtPath:_destinationBundleFilePath error:nil];
	[fileManager removeItemAtPath:[[self downloadBundlePath] stringByAppendingPathComponent:@"Info.plist"] error:nil];
	[fileManager removeItemAtPath:[[self downloadBundlePath] stringByAppendingPathComponent:@"resumedata"] error:nil];
	[fileManager removeItemAtPath:[self downloadBundlePath] error:nil];
	
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ URL='%@'>", NSStringFromClass([self class]), self.URL];
}

#pragma mark - Internal Utilities

- (void)_completeWithError:(NSError *)error
{
	// notify delegate of error
	if ([_delegate respondsToSelector:@selector(download:didFailWithError:)])
	{
		[_delegate download:self didFailWithError:error];
	}
	
	// call completion handler
	if (_completionHandler)
	{
		_completionHandler(nil, error);
	}
	
	_urlConnection = nil;
	
	// send finish notification with error in userInfo
	NSDictionary *userInfo = @{@"Error":error};
	[[NSNotificationCenter defaultCenter] postNotificationName:DTDownloadDidFinishNotification object:self userInfo:userInfo];
}

- (void)_completeWithSuccess
{
	
	if (_headOnly)
	{
		// only a HEAD request
		if ([_delegate respondsToSelector:@selector(downloadDidFinishHEAD:)])
		{
			[_delegate downloadDidFinishHEAD:self];
		}
	}
	else
	{
		// normal GET request
		NSError *error = nil;
		
		NSFileManager *fileManager = [NSFileManager defaultManager];
		
		NSString *fileName = [_destinationBundleFilePath lastPathComponent];
		NSString *targetPath = [[[_destinationBundleFilePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]	stringByAppendingPathComponent:fileName];
		
		if (_temporaryDownloadLocationPath)
		{
			if (![fileManager copyItemAtPath:_temporaryDownloadLocationPath toPath:targetPath error:&error])
			{
				DTLogError(@"Cannot copy item from %@ to %@, %@", _destinationBundleFilePath, targetPath, [error localizedDescription]);
				[self _completeWithError:error];
				return;
			}
		}
		else if (![fileManager moveItemAtPath:_destinationBundleFilePath toPath:targetPath error:&error])
		{
			DTLogError(@"Cannot move item from %@ to %@, %@", _destinationBundleFilePath, targetPath, [error localizedDescription]);
			[self _completeWithError:error];
			return;
		}
		
		if (![fileManager removeItemAtPath:[_destinationBundleFilePath stringByDeletingLastPathComponent] error:&error])
		{
			DTLogError(@"Cannot remove item from %@, %@ ", [_destinationBundleFilePath stringByDeletingLastPathComponent], [error localizedDescription]);
		}
		
		NSData *data = [NSData dataWithContentsOfFile:targetPath options:NSDataReadingMappedIfSafe error:&error];
		
		if (error)
		{
			DTLogError(@"Error occured when reading file from path: %@", targetPath);
		}
		
		// Error: finished file size differs from header size -> so throw error
		if (![NSURLSession class])
		{
			if (_expectedContentLength>0 && [data length] != _expectedContentLength)
			{
				NSString *errorMessage = [NSString stringWithFormat:@"Error: finished file size %d differs from header size %d", (int)[data length], (int)_expectedContentLength];
				
				NSLog(errorMessage, nil);
				
				NSDictionary *userInfo = @{errorMessage : NSLocalizedDescriptionKey};
				
				NSError *error = [NSError errorWithDomain:@"DTDownloadError" code:1 userInfo:userInfo];
				
				[self _completeWithError:error];
				
				return;
			}
		}
		
		// notify delegate
		if ([_delegate respondsToSelector:@selector(download:didFinishWithFile:)])
		{
			[_delegate download:self didFinishWithFile:targetPath];
		}
		
		// run completion handler
		if (_completionHandler)
		{
			_completionHandler(targetPath, nil);
		}
	}
	
	// nil the completion handlers in case they captured self
	_urlConnection = nil;
	_downloadTask = nil;
	
	// send notification
	[[NSNotificationCenter defaultCenter] postNotificationName:DTDownloadDidFinishNotification object:self];
}

#pragma mark - Infos for resuming

- (void)setInfoDictionary:(NSDictionary *)infoDictionary
{
	_URL = [NSURL URLWithString:[infoDictionary objectForKey:DownloadEntryURL]];
	_destinationBundleFilePath = [infoDictionary objectForKey:DownloadEntryPath];
	_expectedContentLength = [[infoDictionary objectForKey:DownloadEntryProgressTotalToLoad] longLongValue];
	NSDictionary *resumeInfo = [infoDictionary objectForKey:DownloadEntryResumeInformation];
	_resumeFileOffset = [[resumeInfo objectForKey:NSURLDownloadBytesReceived] longLongValue];
	_downloadEntityTag = [infoDictionary objectForKey:NSURLDownloadEntityTag];
	_expectedContentLength = [[infoDictionary objectForKey:DownloadEntryProgressTotalToLoad] longLongValue];
}

- (NSDictionary *)infoDictionary
{
	NSMutableDictionary *resumeDictionary = [NSMutableDictionary dictionary];
	[resumeDictionary setObject:[NSNumber numberWithLongLong:_receivedBytes] forKey:NSURLDownloadBytesReceived];
	if (_downloadEntityTag)
	{
		[resumeDictionary setObject:_downloadEntityTag forKey:NSURLDownloadEntityTag];
	}
	[resumeDictionary setObject:[_URL absoluteString] forKey:DownloadEntryURL];
	NSDictionary *infoDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
											  [NSNumber numberWithInt:-999], DownloadEntryErrorCodeDictionaryKey,
											  NSURLErrorDomain, DownloadEntryErrorDomainDictionaryKey,
											  _destinationBundleFilePath, DownloadEntryPath,
											  [NSNumber numberWithLongLong:_receivedBytes], DownloadEntryProgressBytesSoFar,
											  [NSNumber numberWithLongLong:_expectedContentLength], DownloadEntryProgressTotalToLoad,
											  resumeDictionary, DownloadEntryResumeInformation,
											  [_URL absoluteString], DownloadEntryURL
											  , nil];
	
	return infoDictionary;
}

- (void)storeDownloadInfo
{
	// no need to save resume info if we have not received any bytes yet, or download is complete
	if (_receivedBytes == 0 || (_receivedBytes >= _expectedContentLength) || _headOnly)
	{
		return;
	}
	
	NSString *infoPath = [[self downloadBundlePath] stringByAppendingPathComponent:@"Info.plist"];
	[[self infoDictionary] writeToFile:infoPath atomically:YES];
}

#pragma mark - Common download functions

- (void)_didReceiveData:(NSData *)data
{
	
	[self writeToDestinationFile:data];
	
	// calculate a transfer speed
	float downloadSpeed = 0;
	NSDate *now = [NSDate date];
	if (self.lastPacketTimestamp)
	{
		NSTimeInterval downloadDurationForPacket = [now timeIntervalSinceDate:self.lastPacketTimestamp];
		float instantSpeed = [data length] / downloadDurationForPacket;
		
		downloadSpeed = (_previousSpeed * 0.9) + 0.1 * instantSpeed;
	}
	self.lastPacketTimestamp = now;
	// calculation speed done
	
	
	// send notification
	if (_expectedContentLength > 0)
	{
		NSDate *now = [NSDate date];
		
		NSTimeInterval currentProgressInterval = [now timeIntervalSinceDate:_lastProgressSentDate];
		
		// throttling sending of progress notifications for specified progressInterval in seconds
		if (currentProgressInterval > PROGRESS_INTERVAL)
		{
			// notify delegate
			if ([_delegate respondsToSelector:@selector(download:downloadedBytes:ofTotalBytes:withSpeed:)])
			{
				[_delegate download:self downloadedBytes:_receivedBytes ofTotalBytes:_expectedContentLength withSpeed:downloadSpeed];
			}
			
			NSDictionary *userInfo = @{@"ProgressPercent" : [NSNumber numberWithFloat:(float) _receivedBytes / (float) _expectedContentLength], @"TotalBytes" : [NSNumber numberWithLongLong:_expectedContentLength], @"ReceivedBytes" : [NSNumber numberWithLongLong:_receivedBytes]};
			[[NSNotificationCenter defaultCenter] postNotificationName:DTDownloadProgressNotification object:self userInfo:userInfo];
			
			_lastProgressSentDate = [NSDate date];
		}
	}
}


- (void)_didReceiveResponse:(NSURLResponse *)response
{
	if ([response isKindOfClass:[NSHTTPURLResponse class]])
	{
		NSHTTPURLResponse *http = (NSHTTPURLResponse *) response;
		_contentType = http.MIMEType;
		
		if (http.statusCode >= 400)
		{
			NSDictionary *userInfo = [NSDictionary dictionaryWithObject:[NSHTTPURLResponse localizedStringForStatusCode:http.statusCode] forKey:NSLocalizedDescriptionKey];
			
			NSError *error = [NSError errorWithDomain:@"iCatalog" code:http.statusCode userInfo:userInfo];
			
			if ([NSURLSession class])
			{
				[_downloadTask cancel];
				_downloadTask = nil;
			}
			else
			{
				[_urlConnection cancel];
				_urlConnection = nil;
			}
			
			[self _didFailWithError:error];
					
			return;
		}
		
		if (_expectedContentLength <= 0)
		{
			_expectedContentLength = [response expectedContentLength];
			
			if (_expectedContentLength == NSURLResponseUnknownLength)
			{
				DTLogInfo(@"No expected content length for %@", _URL);
			}
		}
		
		NSString *currentEntityTag = [http.allHeaderFields objectForKey:@"Etag"];
		if (!_downloadEntityTag)
		{
			_downloadEntityTag = currentEntityTag;
		}
		else
		{
			// check if it's the same as from last time
			if (![self.downloadEntityTag isEqualToString:currentEntityTag])
			{
				// file was changed on server restart from beginning
				[_urlConnection cancel];
				_urlConnection = nil;
				// update loading flag to allow resume
				[self start];
			}
		}
		
		// get something to identify file
		NSString *modified = [http.allHeaderFields objectForKey:@"Last-Modified"];
		if (modified)
		{
			NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
			[dateFormatter setDateFormat:@"EEE, dd MMM yyyy HH:mm:ss zzz"];
			NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
			[dateFormatter setLocale:locale];
			
			_lastModifiedDate = [dateFormatter dateFromString:modified];
		}
		
		if (_responseHandler)
		{
			_responseHandler([http allHeaderFields], &_shouldCancel);
			
			if (_shouldCancel)
			{
				[self _stopWithResume:NO];
				
				// exit here to avoid adding of download bundle folder
				return;
			}
		}
		
		// if _destinationBundleFilePath is not nil this means that it is a resumable download
		if (!_destinationBundleFilePath)
		{
			_destinationBundleFilePath = [self createBundleFilePathForFilename:[self filenameFromHeader:http.allHeaderFields]];
		}
		
		_isResume = NO;
		
		if (http.statusCode == 206)
		{
			// partial content, so resume
			NSString *contentRange = [[http allHeaderFields] objectForKey:@"Content-Range"];
			
			if (contentRange)
			{
				NSString *expectedContentRangePrefix = [NSString stringWithFormat:@"bytes %lld-", _resumeFileOffset];
				if ([[contentRange lowercaseString] hasPrefix:expectedContentRangePrefix])
				{
					_isResume = YES;
				}
			}
		}
	}
	else
	{
		[_urlConnection cancel];
	}
	// could be redirections, so we set the Length to 0 every time
	[_receivedData setLength:0];
}

- (void)_didFailWithError:(NSError *)error
{
	_receivedData = nil;
	
	[self closeDestinationFile];
	
	[self _completeWithError:error];
}

#pragma mark - NSURLConnection Delegate

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	_urlConnection = nil;
	
	// update resume info on disk
	[self storeDownloadInfo];
	
	[self _didFailWithError:error];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	[self _didReceiveResponse:response];
}

- (NSString *)createBundleFilePathForFilename:(NSString *)fileName
{
	if (_destinationFileName)
	{
		fileName = _destinationFileName;
	}
	else if (!fileName)
	{
		fileName = [[_URL path] lastPathComponent];
	}
	NSString *folderForDownloading = _destinationPath;
	if (!folderForDownloading)
	{
		folderForDownloading = NSTemporaryDirectory();
	}
	
	NSString * fullFileName = [self uniqueFileNameForFile:fileName atDestinationPath:folderForDownloading];
	
	NSString *downloadBundlePath = [folderForDownloading stringByAppendingPathComponent:[fullFileName stringByAppendingPathExtension:@"download"]];
	NSFileManager *fileManager = [NSFileManager defaultManager];
	
	if (![fileManager fileExistsAtPath:self.downloadBundlePath])
	{
		NSError *error;
		if (![fileManager createDirectoryAtPath:downloadBundlePath withIntermediateDirectories:YES attributes:nil error:&error])
		{
			DTLogError(@"Cannot create download folder %@, %@", downloadBundlePath, [error localizedDescription]);
			[self _completeWithError:error];
			return nil;
		}
		
	}
	return [downloadBundlePath stringByAppendingPathComponent:fullFileName];
}


- (NSString *)uniqueFileNameForFile:(NSString *)fileName atDestinationPath:(NSString *)path {
	
	NSString *resultFileName = [path stringByAppendingPathComponent:fileName];
	NSFileManager *fileManager = [NSFileManager defaultManager];
	
	int i=1;
	while ([fileManager fileExistsAtPath:resultFileName] || [fileManager fileExistsAtPath:[resultFileName stringByAppendingPathExtension:@"download"]]) {
		NSString *extension = [fileName pathExtension];
		if ([extension length] > 0) {
			NSInteger endIndex = [fileName length]- [extension length] - 1;
			NSString *basename = [NSString stringWithFormat: @"%@-%d", [fileName substringToIndex:endIndex], i];
			resultFileName = [[path stringByAppendingPathComponent:basename] stringByAppendingPathExtension:extension];
		} else {
			resultFileName = [path stringByAppendingPathComponent:[NSString stringWithFormat: @"%@-%d", fileName, i]];
		}
		
		i++;
	}
	return [resultFileName lastPathComponent];
}

- (NSString *)filenameFromHeader:(NSDictionary *)headerDictionary
{
	NSString *contentDisposition = [headerDictionary objectForKey:@"Content-disposition"];
	
	NSRange range = [contentDisposition rangeOfString:@"filename=\""];
	if (range.location != NSNotFound)
	{
		NSUInteger startIndex = range.location + range.length;
		NSUInteger length = contentDisposition.length - startIndex - 1;
		NSRange newRange = NSMakeRange(startIndex, length);
		return [contentDisposition substringWithRange:newRange];
	}
	return nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	[self _didReceiveData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	_receivedData = nil;
	_urlConnection = nil;
	
	[self closeDestinationFile];
	
	[self _completeWithSuccess];
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
	
	if (!_didReceiveResponse)
	{
		DTLogDebug(@"Response received: %@", downloadTask.response);
		
		// use response only on first call
		[self _didReceiveResponse:downloadTask.response];
		_didReceiveResponse = YES;
	}
	
	_receivedBytes = totalBytesWritten;
	
	NSDate *now = [NSDate date];
	
	NSTimeInterval currentProgressInterval = [now timeIntervalSinceDate:_lastProgressSentDate];
	
	// throttling sending of progress notifications for specified progressInterval in seconds
	if (currentProgressInterval > PROGRESS_INTERVAL)
	{
		// notify delegate
		if ([_delegate respondsToSelector:@selector(download:downloadedBytes:ofTotalBytes:withSpeed:)])
		{
			// TODO: i see no option to calculate download speed with NSURLSession
			[_delegate download:self downloadedBytes:_receivedBytes ofTotalBytes:_expectedContentLength withSpeed:0];
		}
		
		NSDictionary *userInfo = @{@"ProgressPercent" : [NSNumber numberWithFloat:(float) totalBytesWritten / (float) totalBytesExpectedToWrite], @"TotalBytes" : [NSNumber numberWithLongLong:totalBytesExpectedToWrite], @"ReceivedBytes" : [NSNumber numberWithLongLong:totalBytesWritten]};
		[[NSNotificationCenter defaultCenter] postNotificationName:DTDownloadProgressNotification object:self userInfo:userInfo];
		
		DTLogDebug(@"%s - %f", __PRETTY_FUNCTION__, (float) totalBytesWritten / (float) totalBytesExpectedToWrite);
		
		_lastProgressSentDate = [NSDate date];
	}
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
	if (!_downloadTask)
	{
		return;
	}
	
	if (_shouldCancel || _downloadTask.state == NSURLSessionTaskStateCanceling)
	{
		return;
	}
	
	_temporaryDownloadLocationPath = [location path];
	
	DTLogDebug(@"Task: %@ completed successfully", downloadTask);
		
	if (!_didReceiveResponse)
	{
		DTLogDebug(@"Response received: %@", downloadTask.response);
		
		// use response only on first call
		[self _didReceiveResponse:downloadTask.response];
		_didReceiveResponse = YES;
	}
	
	_receivedData = nil;
	_downloadTask = nil;
		
	[self _completeWithSuccess];
}


- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
	_downloadTask = nil;
	
	[self closeDestinationFile];
	
	if (error.code == -999)
	{
		// ignore this -> this error comes when a NSURLSessionDownloadTask is cancelled!? WTF?!
		return;
	}
	
	else if (error)
	{
		DTLogError(@"Task: %@ completed with error: %@", task, [error localizedDescription]);
		
		[self _completeWithError:error];
	}
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes
{
	// nothing to do
}



#pragma mark - Notifications

- (void)appWillTerminate:(NSNotification *)notification
{
	[self stop];
}

/**
 * Writes to the destination file the given data to the end of the file.
 * Also the destination file is opened lazy if needed.
 */
- (void)writeToDestinationFile:(NSData *)data
{
	
	if (!_destinationBundleFilePath)
	{
		// should never happen because in didReceiveResponse the _destinationBundleFilePath is set
		NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"Cannot store the downloaded data"};
		NSError *error = [[NSError alloc] initWithDomain:@"DTDownload" code:100 userInfo:userInfo];
		[self _completeWithError:error];
		return;
	}
	
	if (!_destinationFileHandle)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		if (_isResume && [fileManager fileExistsAtPath:_destinationBundleFilePath])
		{
			_destinationFileHandle = [NSFileHandle fileHandleForWritingAtPath:_destinationBundleFilePath];
			[_destinationFileHandle seekToFileOffset:_resumeFileOffset];
			_receivedBytes = _resumeFileOffset;
		}
		else
		{
			// if file does not exist then create it
			[fileManager createFileAtPath:_destinationBundleFilePath contents:data attributes:nil];
			_receivedBytes = [data length];
			_resumeFileOffset = 0;
			_destinationFileHandle = [NSFileHandle fileHandleForWritingAtPath:_destinationBundleFilePath];
			[_destinationFileHandle seekToEndOfFile];
			// we are done here, so exit
			return;
		}
	}
	
	[_destinationFileHandle writeData:data];
	_receivedBytes += [data length];
}

- (void)closeDestinationFile {
	[_destinationFileHandle closeFile];
	_destinationFileHandle = nil;
}

#pragma mark Properties

- (BOOL)isRunning
{
	return (_urlConnection != nil);
}


- (BOOL)canResume
{
	return _resumeFileOffset > 0;
}

- (NSString *)downloadBundlePath {
	return [_destinationBundleFilePath stringByDeletingLastPathComponent];
}

@synthesize URL = _URL;
@synthesize downloadEntityTag = _downloadEntityTag;
@synthesize lastPacketTimestamp = _lastPacketTimestamp;
@synthesize delegate = _delegate;
@synthesize lastModifiedDate = _lastModifiedDate;
@synthesize contentType = _contentType;
@synthesize expectedContentLength = _expectedContentLength;
@synthesize context = _context;
@synthesize responseHandler = _responseHandler;
@synthesize completionHandler = _completionHandler;
@synthesize additionalHTTPHeaders = _additionalHTTPHeaders;

@end
