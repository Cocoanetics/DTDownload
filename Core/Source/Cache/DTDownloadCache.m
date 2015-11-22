//
//  DTDownloadCache.m
//  DTFoundation
//
//  Created by Oliver Drobnik on 4/20/12.
//  Copyright (c) 2012 Cocoanetics. All rights reserved.
//

#import <ImageIO/CGImageSource.h>

#import <DTFoundation/DTWeakSupport.h>
#import <DTFoundation/NSString+DTPaths.h>
#import <DTFoundation/NSString+DTFormatNumbers.h>

#if TARGET_OS_IPHONE
#import <DTFoundation/DTAsyncFileDeleter.h>
#endif


#import "DTDownloadCache.h"
#import "DTCachedFile.h"
#import "DTDownload.h"

NSString *DTDownloadCacheDidCacheFileNotification = @"DTDownloadCacheDidCacheFile";

@interface DTDownloadCache ()

- (void)_setupCoreDataStack;
- (DTCachedFile *)_cachedFileForURL:(NSURL *)URL inContext:(NSManagedObjectContext *)context;
- (NSArray *)_filesThatNeedToBeDownloadedInContext:(NSManagedObjectContext *)context;
- (NSUInteger)_currentDiskUsageInContext:(NSManagedObjectContext *)context;
- (void)_resetDownloadStatus;
- (void)_commitWorkerContext;

@end

@implementation DTDownloadCache
{
	// Core Data Stack
	NSManagedObjectModel *_managedObjectModel;
	NSPersistentStoreCoordinator *_persistentStoreCoordinator;
	
	NSManagedObjectContext *_writerContext;
	NSManagedObjectContext *_workerContext;
	
	// Internals
	NSMutableSet *_activeDownloads;
	
	// memory cache for certain types, e.g. images
	NSCache *_memoryCache;
	NSCache *_entityCache;
	
	NSUInteger _maxNumberOfConcurrentDownloads;
	NSUInteger _diskCapacity;
	
	// completion handling
	NSMutableDictionary *_completionHandlers;
	
	// timer that frequently writes the MOC
	NSTimer *_saveTimer;
	
	// timer that does cache maintenance
	NSTimer *_maintenanceTimer;
	BOOL _needsMaintenance;
    
    // image decompression
    dispatch_queue_t _decompressionQueue;
}

+ (DTDownloadCache *)sharedInstance
{
	static dispatch_once_t onceToken;
	static DTDownloadCache *_sharedInstance;
	
	dispatch_once(&onceToken, ^{
		_sharedInstance = [[DTDownloadCache alloc] init];
	});
	
	return _sharedInstance;
}

- (id)init
{
	self = [super init];
	{
		[self _setupCoreDataStack];
		
		_activeDownloads = [[NSMutableSet alloc] init];
		
		_memoryCache = [[NSCache alloc] init];
		_entityCache = [[NSCache alloc] init];
		
		_maxNumberOfConcurrentDownloads = 1;
		_diskCapacity = 1024*1024*20; // 20 MB
		
		_completionHandlers = [[NSMutableDictionary alloc] init];
		
		// preload cached object identifiers to speed up initial access
		[self _preloadCachedFileIDs];
		
		// reset status of downloads
		[self _resetDownloadStatus];
		
        _decompressionQueue = dispatch_queue_create("DTDownloadCache Decompression Queue", 0);
        
		_saveTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(_saveTimerTick:) userInfo:nil repeats:YES];
		
		_maintenanceTimer = [NSTimer scheduledTimerWithTimeInterval:60.0 target:self selector:@selector(_maintenanceTimerTick:) userInfo:nil repeats:YES];
		
#if TARGET_OS_IPHONE
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
#endif
	}
	
	return self;
}

// should never be called, since this is a singleton
- (void)dealloc
{
	[_saveTimer invalidate];
	_saveTimer = nil;
	
	[_maintenanceTimer invalidate];
	_maintenanceTimer = nil;
	
	[self _writeToDisk];
    
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_preloadCachedFileIDs
{
	[_workerContext performBlockAndWait:^{
		NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"DTCachedFile"];
		request.fetchLimit = 0;
		
		NSError *error;
		NSArray *results = [_workerContext executeFetchRequest:request error:&error];
		
		if (!results)
		{
			NSLog(@"error occured fetching %@", [error localizedDescription]);
		}
		
		for (DTCachedFile *cachedFile in results)
		{
			// cache the file entity for this URL
			NSURL *remoteURL = [NSURL URLWithString:cachedFile.remoteURL];
			NSString *cacheKey = [remoteURL absoluteString];
			
			[_entityCache setObject:cachedFile.objectID forKey:cacheKey];
		}
	}];
}

#pragma mark Queue Handling

// only called from _workerContext
- (void)_startDownloadForURL:(NSURL *)URL shouldAbortIfNotNewer:(BOOL)shouldAbortIfNotNewer context:(id)context
{
	DTDownload *download = [[DTDownload alloc] initWithURL:URL];
	download.delegate = self;
	download.context = context;
	
	if (shouldAbortIfNotNewer)
	{
		DTCachedFile *cachedFile = [self _cachedFileForURL:URL inContext:_workerContext];
		
		if (cachedFile)
		{
			NSString *cachedETag = cachedFile.entityTagIdentifier;
			NSDate *lastModifiedDate = cachedFile.lastModifiedDate;
            
            if (lastModifiedDate)
            {
                NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
                [dateFormatter setDateFormat:@"EEE, dd MMM yyyy HH:mm:ss zzz"];
                NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_GB"];
                [dateFormatter setLocale:locale];
               // [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
                
                NSString *dateStr = [dateFormatter stringFromDate:lastModifiedDate];
                
                download.additionalHTTPHeaders = @{@"If-Modified-Since": dateStr};
            }
			
			DT_WEAK_VARIABLE DTDownload *weakDownload = download;
			
			download.responseHandler = ^(NSDictionary *headers, BOOL *shouldCancel) {
				if (cachedETag)
				{
					if ([weakDownload.downloadEntityTag isEqualToString:cachedETag])
					{
						*shouldCancel = YES;
					}
				}
				
				if (lastModifiedDate)
				{
					if ([weakDownload.lastModifiedDate isEqualToDate:lastModifiedDate])
					{
						*shouldCancel = YES;
					}
				}
			};
		}
	}
	
	
	[_activeDownloads addObject:download];
	[download start];
}

- (void)_removeDownloadFromActiveDownloads:(DTDownload *)download
{
	[_workerContext performBlock:^{
		DTCachedFile *cachedFile = [self _cachedFileForURL:download.URL inContext:_workerContext];
		
		// we need to reset the loading status so that it will get retried next time if necessary
		if ([cachedFile.isLoading boolValue])
		{
			cachedFile.isLoading = [NSNumber numberWithBool:NO];
		}
		
		if ([cachedFile.forceLoad boolValue])
		{
			cachedFile.forceLoad = [NSNumber numberWithBool:NO];
		}
		
		[self _commitWorkerContext];
		
		[_activeDownloads removeObject:download];
		
		[self _unregisterAllCompletionBlocksForURL:download.URL];
	}];
}

- (void)_startNextQueuedDownload
{
	[_workerContext performBlock:^{
		NSUInteger activeDownloads = [_activeDownloads count];
		
		// early exit if the queue is full
		if (activeDownloads>=_maxNumberOfConcurrentDownloads)
		{
			return;
		}
		
		NSArray *filesToDownload = [self _filesThatNeedToBeDownloadedInContext:_workerContext];
		
		for (DTCachedFile *oneFile in filesToDownload)
		{
			if (activeDownloads < _maxNumberOfConcurrentDownloads)
			{
				oneFile.isLoading = [NSNumber numberWithBool:YES];
				
				BOOL shouldAbortIfNotNewer = [oneFile.abortDownloadIfNotChanged boolValue];
				
				NSURL *URL = [NSURL URLWithString:oneFile.remoteURL];
				id context = [oneFile objectID];
				[self _startDownloadForURL:URL shouldAbortIfNotNewer:shouldAbortIfNotNewer context:context];
				
				activeDownloads++;
			}
		}
	}];
}

#pragma mark External Methods

- (NSData *)cachedDataForURL:(NSURL *)URL option:(DTDownloadCacheOption)option completion:(DTDownloadCacheDataCompletionBlock)completion
{
	return [self cachedDataForURL:URL option:option priority:DTDownloadCachePriorityNormal completion:completion];
}

- (NSData *)cachedDataForURL:(NSURL *)URL option:(DTDownloadCacheOption)option priority:(DTDownloadCachePriority)priority completion:(DTDownloadCacheDataCompletionBlock)completion
{
	NSAssert(![URL isFileURL], @"URL may not be a file URL in DTDownloadCache");
	
	__block NSData *retData = nil;
	
	[_workerContext performBlockAndWait:^{
		DTCachedFile *cachedFile = [self _cachedFileForURL:URL inContext:_workerContext];
		
		if (cachedFile)
		{
			if ([cachedFile.fileData length] == [cachedFile.fileSize longLongValue])
			{
				retData = cachedFile.fileData;
			}
			else
			{
				// data is corrupt
				NSLog(@"Removed corrupt cached file for %@, treat as not downloaded", URL);
				
				cachedFile.fileData = nil;
				cachedFile.entityTagIdentifier = nil;
				cachedFile.lastModifiedDate = nil;
				
				if (priority < [cachedFile.priority unsignedIntegerValue])
				{
					// update priority only if it is requested higher
					cachedFile.priority = [NSNumber numberWithUnsignedLong:(unsigned long)priority];
				}
			}
		}
		else
		{
			// always create the DTCachedFile for a new request
			
			cachedFile = (DTCachedFile *)[NSEntityDescription insertNewObjectForEntityForName:@"DTCachedFile" inManagedObjectContext:_workerContext];
			
			cachedFile.remoteURL = [URL absoluteString];
			cachedFile.expirationDate = [NSDate distantFuture];
			cachedFile.forceLoad = [NSNumber numberWithBool:YES];
			cachedFile.isLoading = [NSNumber numberWithBool:NO];
			cachedFile.priority = [NSNumber numberWithUnsignedLong:(unsigned long)priority];
		}
		
		cachedFile.lastAccessDate = [NSDate date];
		
		switch (option)
		{
			case DTDownloadCacheOptionNeverLoad:
			{
				break;
			}
				
			case DTDownloadCacheOptionLoadIfNotCached:
			{
				if (retData)
				{
					cachedFile.forceLoad = [NSNumber numberWithBool:NO];
				}
				else
				{
					cachedFile.forceLoad = [NSNumber numberWithBool:YES];
				}
				
				break;
			}
				
			case DTDownloadCacheOptionReturnCacheAndLoadAlways:
			{
				cachedFile.forceLoad = [NSNumber numberWithBool:YES];
				cachedFile.abortDownloadIfNotChanged = @(NO);
				
				break;
			}
				
			case DTDownloadCacheOptionReturnCacheAndLoadIfChanged:
			{
				cachedFile.forceLoad = [NSNumber numberWithBool:YES];
				cachedFile.abortDownloadIfNotChanged = [NSNumber numberWithBool:YES];
				
				break;
			}
		}
		
		// will be loading
		if ([cachedFile.forceLoad boolValue])
		{
			if (completion)
			{
				[self _registerCompletion:completion forURL:URL];
			}
		}
		
		// save this
		[self _commitWorkerContext];
		
		
		[self _startNextQueuedDownload];
		
		return; // retData is set
	}];
	
	return retData;
}

- (NSData *)cachedDataForURL:(NSURL *)URL option:(DTDownloadCacheOption)option
{
	return [self cachedDataForURL:URL option:option priority:DTDownloadCachePriorityNormal];
}

- (NSData *)cachedDataForURL:(NSURL *)URL option:(DTDownloadCacheOption)option priority:(DTDownloadCachePriority)priority
{
	return [self cachedDataForURL:URL option:option completion:NULL];
}

- (NSUInteger)currentDiskUsage
{
	return [self _currentDiskUsageInContext:_workerContext];
}

#pragma mark DTDownload

- (void)download:(DTDownload *)download didFailWithError:(NSError *)error
{
	[_workerContext performBlock:^{
		NSString *key = [download.URL absoluteString];
		NSArray *blocksToExecute = _completionHandlers[key];
		
		// excecute all blocks and forward the error
		for (DTDownloadCacheDataCompletionBlock oneBlock in blocksToExecute)
		{
			oneBlock(download.URL, nil, error);
		}
		
		[self _removeDownloadFromActiveDownloads:download];
		
		[self _startNextQueuedDownload];
	}];
}

- (void)downloadDidCancel:(DTDownload *)download
{
	[_workerContext performBlock:^{
		[self _removeDownloadFromActiveDownloads:download];
		
		[self _startNextQueuedDownload];
	}];
}

- (void)download:(DTDownload *)download didFinishWithFile:(NSString *)path
{
	NSURL *URL = download.URL;
	
	[_workerContext performBlock:^{
		
		NSError *error = nil;
		NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
		
		if (error)
		{
			NSLog(@"Error occured when reading file from path: %@", path);
		}
		
		// only add cached file if we actually got data in it
		if (data)
		{
			// get the cached file entity for this download via the managed object id which is in the download context
			DTCachedFile *cachedFile = (DTCachedFile *)[_workerContext objectWithID:download.context];
			
			if (!cachedFile)
			{
				NSLog(@"Warning, did not find DTCachedFile for download");
				
				cachedFile = [self _cachedFileForURL:URL inContext:_workerContext];
			}
			
			NSAssert(cachedFile, @"Problem, there was no file in the queue for a finished download!");
			
			cachedFile.lastModifiedDate = download.lastModifiedDate;
			cachedFile.entityTagIdentifier = download.downloadEntityTag;
			cachedFile.fileData = data;
			cachedFile.fileSize = [NSNumber numberWithLongLong:[data length]];
			cachedFile.contentType = download.contentType;
			cachedFile.remoteURL = [URL absoluteString];
			
			// make sure that this is no longer picked up by files needing download
			cachedFile.forceLoad = [NSNumber numberWithBool:NO];
			cachedFile.isLoading = [NSNumber numberWithBool:NO];
			cachedFile.abortDownloadIfNotChanged = [NSNumber numberWithBool:NO];
			
			[self _commitWorkerContext];
			
#if TARGET_OS_IPHONE
			// we transfered the file into the database, so we don't need it any more
			[[DTAsyncFileDeleter sharedInstance] removeItemAtPath:path];
#else
			[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
#endif
			
			NSString *key = [download.URL absoluteString];
			NSArray *blocksToExecute = _completionHandlers[key];
			
			// excecute all blocks and forward the error
			for (DTDownloadCacheDataCompletionBlock oneBlock in blocksToExecute)
			{
				oneBlock(URL, data, nil);
			}
			
			// remove from active downloads
			[self _removeDownloadFromActiveDownloads:download];
			
			// completion block and notification
			dispatch_async(dispatch_get_main_queue(), ^{
				// send notification
				NSDictionary *info = @{@"URL": URL};
				[[NSNotificationCenter defaultCenter] postNotificationName:DTDownloadCacheDidCacheFileNotification object:self userInfo:info];
			});
		}
		
		[self _startNextQueuedDownload];
	}];
}


#pragma mark CoreData Stack

- (NSManagedObjectModel *)_model
{
	NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
	
	// create the entity
	NSEntityDescription *entity = [[NSEntityDescription alloc] init];
	[entity setName:@"DTCachedFile"];
	[entity setManagedObjectClassName:@"DTCachedFile"];
	
	// create the attributes
	NSMutableArray *properties = [NSMutableArray array];
	
	NSAttributeDescription *remoteURLAttribute = [[NSAttributeDescription alloc] init];
	[remoteURLAttribute setName:@"remoteURL"];
	[remoteURLAttribute setAttributeType:NSStringAttributeType];
	[remoteURLAttribute setOptional:NO];
	[remoteURLAttribute setIndexed:YES];
	[properties addObject:remoteURLAttribute];
	
	NSAttributeDescription *fileDataAttribute = [[NSAttributeDescription alloc] init];
	[fileDataAttribute setName:@"fileData"];
	[fileDataAttribute setAttributeType:NSBinaryDataAttributeType];
	[fileDataAttribute setOptional:YES];
	[fileDataAttribute setAllowsExternalBinaryDataStorage:YES];
	[properties addObject:fileDataAttribute];
	
	NSAttributeDescription *lastAccessDateAttribute = [[NSAttributeDescription alloc] init];
	[lastAccessDateAttribute setName:@"lastAccessDate"];
	[lastAccessDateAttribute setAttributeType:NSDateAttributeType];
	[lastAccessDateAttribute setOptional:NO];
	[properties addObject:lastAccessDateAttribute];
	
	NSAttributeDescription *lastModifiedDateAttribute = [[NSAttributeDescription alloc] init];
	[lastModifiedDateAttribute setName:@"lastModifiedDate"];
	[lastModifiedDateAttribute setAttributeType:NSDateAttributeType];
	[lastModifiedDateAttribute setOptional:YES];
	[properties addObject:lastModifiedDateAttribute];
	
	NSAttributeDescription *expirationDateAttribute = [[NSAttributeDescription alloc] init];
	[expirationDateAttribute setName:@"expirationDate"];
	[expirationDateAttribute setAttributeType:NSDateAttributeType];
	[expirationDateAttribute setOptional:NO];
	[properties addObject:expirationDateAttribute];
	
	NSAttributeDescription *contentTypeAttribute = [[NSAttributeDescription alloc] init];
	[contentTypeAttribute setName:@"contentType"];
	[contentTypeAttribute setAttributeType:NSStringAttributeType];
	[contentTypeAttribute setOptional:YES];
	[properties addObject:contentTypeAttribute];
	
	NSAttributeDescription *fileSizeAttribute = [[NSAttributeDescription alloc] init];
	[fileSizeAttribute setName:@"fileSize"];
	[fileSizeAttribute setAttributeType:NSInteger32AttributeType];
	[fileSizeAttribute setOptional:YES];
	[properties addObject:fileSizeAttribute];
	
	NSAttributeDescription *forceLoadAttribute = [[NSAttributeDescription alloc] init];
	[forceLoadAttribute setName:@"forceLoad"];
	[forceLoadAttribute setAttributeType:NSBooleanAttributeType];
	[forceLoadAttribute setOptional:YES];
	[properties addObject:forceLoadAttribute];
	
	NSAttributeDescription *abortAttribute = [[NSAttributeDescription alloc] init];
	[abortAttribute setName:@"abortDownloadIfNotChanged"];
	[abortAttribute setAttributeType:NSBooleanAttributeType];
	[abortAttribute setOptional:YES];
	[properties addObject:abortAttribute];
	
	NSAttributeDescription *loadingAttribute = [[NSAttributeDescription alloc] init];
	[loadingAttribute setName:@"isLoading"];
	[loadingAttribute setAttributeType:NSBooleanAttributeType];
	[loadingAttribute setOptional:NO];
	[properties addObject:loadingAttribute];
	
	NSAttributeDescription *entityTagIdentifierAttribute = [[NSAttributeDescription alloc] init];
	[entityTagIdentifierAttribute setName:@"entityTagIdentifier"];
	[entityTagIdentifierAttribute setAttributeType:NSStringAttributeType];
	[entityTagIdentifierAttribute setOptional:YES];
	[properties addObject:entityTagIdentifierAttribute];
	
	NSAttributeDescription *priorityAttribute = [[NSAttributeDescription alloc] init];
	[priorityAttribute setName:@"priority"];
	[priorityAttribute setAttributeType:NSInteger32AttributeType];
	[priorityAttribute setOptional:YES];
	[properties addObject:priorityAttribute];
	
	// add attributes to entity
	[entity setProperties:properties];
	
	// add entity to model
	[model setEntities:[NSArray arrayWithObject:entity]];
	
	return model;
}

- (void)_setupCoreDataStack
{
	// setup managed object model
	
	/*
	 NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"DTDownloadCache" withExtension:@"momd"];
	 _managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
	 */
	
	// in code
	_managedObjectModel = [self _model];
	
	// setup persistent store coordinator
	NSURL *storeURL = [NSURL fileURLWithPath:[[NSString cachesPath] stringByAppendingPathComponent:@"DTDownload.cache"]];
	
	NSError *error = nil;
	_persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:_managedObjectModel];
	
	if (![_persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error])
	{
		// inconsistent model/store
		[[NSFileManager defaultManager] removeItemAtURL:storeURL error:NULL];
		
		// retry once
		if (![_persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error])
		{
			NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
			abort();
		}
	}
	
	// create writer MOC
	_writerContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
	[_writerContext setPersistentStoreCoordinator:_persistentStoreCoordinator];
	
	// create worker MOC for background operations
	_workerContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
	_workerContext.parentContext = _writerContext;
}

// returned objects can only be used from the same context
- (DTCachedFile *)_cachedFileForURL:(NSURL *)URL inContext:(NSManagedObjectContext *)context
{
	NSString *cacheKey = [URL absoluteString];
	NSManagedObjectID *cachedIdentifier = [_entityCache objectForKey:cacheKey];
	
	if (cachedIdentifier)
	{
		DTCachedFile *cachedFile = (DTCachedFile *)[context objectWithID:cachedIdentifier];
		
		return cachedFile;
	}
	
	
	NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"DTCachedFile"];
	
	request.predicate = [NSPredicate predicateWithFormat:@"remoteURL == %@", [URL absoluteString]];
	request.fetchLimit = 1;
	
	NSError *error;
	NSArray *results = [context executeFetchRequest:request error:&error];
	
	if (!results)
	{
		NSLog(@"error occured fetching %@", [error localizedDescription]);
	}
	
	DTCachedFile *cachedFile = [results lastObject];
	
	if (cachedFile)
	{
		// cache the file entity for this URL
		[_entityCache setObject:cachedFile.objectID forKey:cacheKey];
	}
	
	return cachedFile;
}

- (NSArray *)_filesThatNeedToBeDownloadedInContext:(NSManagedObjectContext *)context
{
	NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"DTCachedFile"];
	
	// load first added URLs first or last added URLs first -> depends on setting
	NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"lastAccessDate" ascending:!_loadLastAddedURLFirst];
	
	NSSortDescriptor *prioritySortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"priority" ascending:YES];
	
	request.sortDescriptors = [NSArray arrayWithObjects:prioritySortDescriptor, sort, nil];
	
	request.predicate = [NSPredicate predicateWithFormat:@"forceLoad == YES and isLoading == NO"];
	request.fetchLimit = _maxNumberOfConcurrentDownloads;
	
	NSError *error;
	
	NSArray *results = [context executeFetchRequest:request error:&error];
	if (!results)
	{
		NSLog(@"Error fetching download files: %@", [error localizedDescription]);
	}
	
	return results;
}

// only call this from within a worker performBlock
- (void)_commitWorkerContext
{
	if ([_workerContext hasChanges])
	{
		_needsMaintenance = YES;
		
		NSError *error = nil;
		if (![_workerContext save:&error])
		{
			NSLog(@"Error saving worker context: %@", [error localizedDescription]);
			return;
		}
	}
}

// this does the actual saving to disk
- (void)_writeToDisk
{
	[_writerContext performBlock:^{
		if ([_writerContext hasChanges])
		{
			NSError *error = nil;
			if (![_writerContext save:&error])
			{
				NSLog(@"Error saving writer context: %@", [error localizedDescription]);
				return;
			}
		}
	}];
}

#pragma mark Maintenance

- (NSUInteger)_currentDiskUsageInContext:(NSManagedObjectContext *)context
{
	NSExpression *ex = [NSExpression expressionForFunction:@"sum:"
																arguments:[NSArray arrayWithObject:[NSExpression expressionForKeyPath:@"fileSize"]]];
	
	NSExpressionDescription *ed = [[NSExpressionDescription alloc] init];
	[ed setName:@"result"];
	[ed setExpression:ex];
	[ed setExpressionResultType:NSInteger64AttributeType];
	
	NSArray *properties = [NSArray arrayWithObject:ed];
	
	NSFetchRequest *request = [[NSFetchRequest alloc] init];
	[request setPropertiesToFetch:properties];
	[request setResultType:NSDictionaryResultType];
	
	NSEntityDescription *entity = [NSEntityDescription entityForName:@"DTCachedFile" inManagedObjectContext:context];
	[request setEntity:entity];
	
	NSArray *results = [context executeFetchRequest:request error:nil];
	NSDictionary *resultsDictionary = [results objectAtIndex:0];
	NSNumber *resultValue = [resultsDictionary objectForKey:@"result"];
	
	return [resultValue unsignedIntegerValue];
}

- (void)_removeExpiredFilesInContext:(NSManagedObjectContext *)context removedBytes:(long long *)removedBytes
{
	NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"DTCachedFile"];
	
	request.predicate = [NSPredicate predicateWithFormat:@"expirationDate < %@", [NSDate date]];
	
	NSError *error;
	NSArray *results = [context executeFetchRequest:request error:&error];
	
	if (!results)
	{
		NSLog(@"error occured fetching %@", [error localizedDescription]);
		return;
	}
	
	long long bytesRemoved = 0;
	
	for (DTCachedFile *cachedFile in results)
	{
		bytesRemoved += [cachedFile.fileSize longLongValue];
		
		// also remove from entity cache
		[_entityCache removeObjectForKey:cachedFile.remoteURL];
		
		[context deleteObject:cachedFile];
	}
	
	if (removedBytes)
	{
		*removedBytes = bytesRemoved;
	}
}

- (void)_removeFilesOverCapacity:(NSUInteger)capacity inContext:(NSManagedObjectContext *)context removedBytes:(long long *)removedBytes
{
	NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"DTCachedFile"];
	[request setFetchBatchSize:0];
	
	NSPredicate *predicate = [NSPredicate predicateWithFormat:@"forceLoad == NO and isLoading == NO"];
	request.predicate = predicate;
	
	NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"lastAccessDate" ascending:NO];
	request.sortDescriptors = [NSArray arrayWithObject:sort];
	
	NSError *error;
	NSArray *results = [context executeFetchRequest:request error:&error];
	
	if (!results)
	{
		NSLog(@"error occured fetching %@", [error localizedDescription]);
		return;
	}
	
	long long capacitySoFar = 0;
	long long bytesRemoved = 0;
	
	for (DTCachedFile *cachedFile in results)
	{
		long long fileSize = [cachedFile.fileSize longLongValue];
		
		capacitySoFar += fileSize;
		
		if (capacitySoFar > capacity)
		{
			bytesRemoved += fileSize;
			
			// also remove from entity cache
			[_entityCache removeObjectForKey:cachedFile.remoteURL];
			
			[context deleteObject:cachedFile];
		}
	}
	
	if (removedBytes)
	{
		*removedBytes = bytesRemoved;
	}
}

- (void)_runMaintenance
{
	[_workerContext performBlock:^{
		// save any worker context stuff that is still in flight
		[self _commitWorkerContext];
		
		NSUInteger diskUsageBeforeMaintenance = [self _currentDiskUsageInContext:_workerContext];
		NSUInteger diskUsageAfterMaintenance = diskUsageBeforeMaintenance;
		
		long long removedBytes = 0;
		
		// remove all expired files
		[self _removeExpiredFilesInContext:_workerContext removedBytes:&removedBytes];
		
		diskUsageAfterMaintenance -= removedBytes;
		
		// prune oldest accessed files so that we get below disk usage limit
		if (diskUsageBeforeMaintenance>_diskCapacity)
		{
			[self _removeFilesOverCapacity:_diskCapacity inContext:_workerContext removedBytes:&removedBytes];
		}
		
		diskUsageAfterMaintenance -= removedBytes;
		
		// only commit if there are actually modifications
		[self _commitWorkerContext];
		
		NSLog(@"Running Maintenance, Usage Before: %@, After: %@", [NSString stringByFormattingBytes:diskUsageBeforeMaintenance], [NSString stringByFormattingBytes:diskUsageAfterMaintenance]);
	}];
}

- (void)_resetDownloadStatus
{
	[_workerContext performBlockAndWait:^{
		NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"DTCachedFile"];
		
		NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"lastAccessDate" ascending:NO];
		request.sortDescriptors = [NSArray arrayWithObject:sort];
		
		request.predicate = [NSPredicate predicateWithFormat:@"isLoading == YES"];
		
		NSError *error;
		
		NSArray *results = [_workerContext executeFetchRequest:request error:&error];
		if (!results)
		{
			NSLog(@"Error cleaning up download status: %@", [error localizedDescription]);
		}
		
		for (DTCachedFile *oneFile in results)
		{
			oneFile.isLoading = [NSNumber numberWithBool:NO];
		}
		
		[self _commitWorkerContext];
	}];
}

- (void)_saveTimerTick:(NSTimer *)timer
{
	[self _writeToDisk];
}

- (void)_maintenanceTimerTick:(NSTimer *)timer
{
	if (_needsMaintenance)
	{
		[self _runMaintenance];
		
		_needsMaintenance = NO;
	}
}

#pragma mark Completion Blocks

- (void)_registerCompletion:(DTDownloadCacheDataCompletionBlock)completion forURL:(NSURL *)URL
{
	NSString *key = [URL absoluteString];
	
	NSMutableArray *completionBlocksForURL = _completionHandlers[key];
	
	if (!completionBlocksForURL)
	{
		completionBlocksForURL = [[NSMutableArray alloc] init];
		_completionHandlers[key] = completionBlocksForURL;
	}
	
	[completionBlocksForURL addObject:[completion copy]];
}

- (void)_unregisterAllCompletionBlocksForURL:(NSURL *)URL
{
	NSString *key = [URL absoluteString];
	
	[_completionHandlers removeObjectForKey:key];
}

#pragma mark - Notifications

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
	// do a maintenance
	[self _runMaintenance];
	
	// do an extra save to be sure that our changes were persisted
	[self _writeToDisk];
}

#pragma mark - Properties

- (void)setMaxNumberOfConcurrentDownloads:(NSUInteger)maxNumberOfConcurrentDownloads
{
	if (_maxNumberOfConcurrentDownloads != maxNumberOfConcurrentDownloads)
	{
		BOOL downloadsWerePaused = _maxNumberOfConcurrentDownloads <= 0;
		
		_maxNumberOfConcurrentDownloads = maxNumberOfConcurrentDownloads;
		
		if (downloadsWerePaused)
		{
			[self _startNextQueuedDownload];
		}
	}
}

- (void)setDiskCapacity:(NSUInteger)diskCapacity
{
	if (diskCapacity!=_diskCapacity)
	{
		_diskCapacity = diskCapacity;
		
		[self _runMaintenance];
	}
}

@synthesize maxNumberOfConcurrentDownloads = _maxNumberOfConcurrentDownloads;
@synthesize diskCapacity = _diskCapacity;

@end


#if TARGET_OS_IPHONE

@implementation DTDownloadCache (Images)

//TODO: make this thread-safe to be called from background threads

- (UIImage *)cachedImageForURL:(NSURL *)URL option:(DTDownloadCacheOption)option completion:(DTDownloadCacheImageCompletionBlock)completion
{
	return [self cachedImageForURL:URL option:option priority:DTDownloadCachePriorityNormal completion:completion];
}

- (UIImage *)cachedImageForURL:(NSURL *)URL option:(DTDownloadCacheOption)option priority:(DTDownloadCachePriority)priority completion:(DTDownloadCacheImageCompletionBlock)completion
{
	
	// try memory cache first
	UIImage *cachedImage = [_memoryCache objectForKey:URL];
	
	if (cachedImage && !DTDownloadCacheOptionReturnCacheAndLoadAlways)
	{
		return cachedImage;
	}
	
	// create a special wrapper completion handler
	DTDownloadCacheDataCompletionBlock internalBlock = NULL;
	
	if (completion)
	{
		internalBlock = ^(NSURL *URL, NSData *data, NSError *error)
		{
			dispatch_async(_decompressionQueue, ^{
				UIImage *cachedImage = nil;
				
                if (data)
                {
                    // make an image out of the data
                    cachedImage = [UIImage imageWithData:data];
                    NSUInteger cost = (NSUInteger)(cachedImage.size.width * cachedImage.size.height);
                    
                    if (cachedImage)
                    {
                        // redraw image using device context if it is not too large
                        if (cost < 1024*1024)
                        {
                            UIGraphicsBeginImageContextWithOptions(cachedImage.size, NO, 0);
                            
                            CGContextRef context = UIGraphicsGetCurrentContext();
                            
                            // sanity check, only do it if we got a context
                            if (context)
                            {
                                [cachedImage drawAtPoint:CGPointZero];
                                cachedImage = UIGraphicsGetImageFromCurrentImageContext();
                            }
                            
                            UIGraphicsEndImageContext();
                        }
                        
                        // put in memory cache
                        [_memoryCache setObject:cachedImage forKey:URL cost:cost];
                    }
                }
				
				// execute wrapped completion block
				completion(URL, cachedImage, error);
			});
		};
	}
	
	// try file cache, this triggers a new load
	NSData *data = [self cachedDataForURL:URL option:option completion:internalBlock];
	
	if (cachedImage)
	{
        // return from memory cache
		return cachedImage;
	}
    
    if (!data)
    {
        return nil;
    }
    
    // try unpacking from cached data
    @try
    {
        cachedImage = [UIImage imageWithData:data];
    }
    @catch (NSException *exception)
    {
        NSLog(@"%@", exception);
    }
    @finally
    {
    }
	
	if (!cachedImage)
	{
		NSLog(@"Illegal Data cached for %@", URL);
		
		[_memoryCache removeObjectForKey:URL];
		return nil;
	}
	
	// put in memory cache
	NSUInteger cost = (NSUInteger)(cachedImage.size.width * cachedImage.size.height);
	[_memoryCache setObject:cachedImage forKey:URL cost:cost];
	
	return cachedImage;
}

- (UIImage *)cachedImageForURL:(NSURL *)URL option:(DTDownloadCacheOption)option
{
	return [self cachedImageForURL:URL option:option priority:DTDownloadCachePriorityNormal];
}

- (UIImage *)cachedImageForURL:(NSURL *)URL option:(DTDownloadCacheOption)option priority:(DTDownloadCachePriority)priority
{
	return [self cachedImageForURL:URL option:option completion:NULL];
}

@end

#endif
