//
//  RMDatabaseCache.m
//
// Copyright (c) 2008-2009, Route-Me Contributors
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import "RMDatabaseCache.h"
#import "FMDatabase.h"
#import "FMDatabaseQueue.h"
#import "RMTileImage.h"
#import "RMTile.h"

#define kWriteQueueLimit 15

@interface RMDatabaseCache ()

- (NSUInteger)count;
- (NSUInteger)countTiles;
- (void)touchTile:(RMTile)tile withKey:(NSString *)cacheKey;
- (void)purgeTiles:(NSUInteger)count;

@end

#pragma mark -

@implementation RMDatabaseCache
{
    // Database
    FMDatabaseQueue *queue;

    NSUInteger tileCount;
    NSOperationQueue *writeQueue;
    NSRecursiveLock *writeQueueLock;

    // Cache
	RMCachePurgeStrategy purgeStrategy;
	NSUInteger capacity;
	NSUInteger minimalPurge;
}

@synthesize databasePath;

+ (NSString *)dbPathUsingCacheDir:(BOOL)useCacheDir
{
	NSArray *paths;

	if (useCacheDir)
		paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
	else
		paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);

	if ([paths count] > 0) // Should only be one...
	{
		NSString *cachePath = [paths objectAtIndex:0];

		// check for existence of cache directory
		if ( ![[NSFileManager defaultManager] fileExistsAtPath: cachePath])
		{
			// create a new cache directory
			[[NSFileManager defaultManager] createDirectoryAtPath:cachePath withIntermediateDirectories:NO attributes:nil error:nil];
		}

		NSString *filename = [NSString stringWithFormat:@"RMTileCache.db"];
		return [cachePath stringByAppendingPathComponent:filename];
	}

	return nil;
}

- (void)configureDBForFirstUse
{
    [queue inDatabase:^(FMDatabase *db) {
        [[db executeQuery:@"PRAGMA synchronous=OFF"] close];
        [[db executeQuery:@"PRAGMA journal_mode=OFF"] close];
        [[db executeQuery:@"PRAGMA cache-size=100"] close];
        [[db executeQuery:@"PRAGMA count_changes=OFF"] close];
        [db executeUpdate:@"CREATE TABLE IF NOT EXISTS ZCACHE (tile_hash INTEGER NOT NULL, cache_key VARCHAR(25) NOT NULL, last_used DOUBLE NOT NULL, data BLOB NOT NULL)"];
        [db executeUpdate:@"CREATE UNIQUE INDEX IF NOT EXISTS main_index ON ZCACHE(tile_hash, cache_key)"];
        [db executeUpdate:@"CREATE INDEX IF NOT EXISTS last_used_index ON ZCACHE(last_used)"];
    }];
}

- (id)initWithDatabase:(NSString *)path
{
	if (!(self = [super init]))
		return nil;

	self.databasePath = path;

    writeQueue = [NSOperationQueue new];
    [writeQueue setMaxConcurrentOperationCount:1];
    writeQueueLock = [NSRecursiveLock new];

	RMLog(@"Opening database at %@", path);

    queue = [[FMDatabaseQueue databaseQueueWithPath:path] retain];

	if (!queue)
	{
		RMLog(@"Could not connect to database");

        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

        [self release];
        return nil;
	}

    [queue inDatabase:^(FMDatabase *db) {
        [db setCrashOnErrors:TRUE];
        [db setShouldCacheStatements:TRUE];
    }];

	[self configureDBForFirstUse];

    tileCount = [self countTiles];

	return self;	
}

- (id)initUsingCacheDir:(BOOL)useCacheDir
{
	return [self initWithDatabase:[RMDatabaseCache dbPathUsingCacheDir:useCacheDir]];
}

- (void)dealloc
{
    self.databasePath = nil;
    [writeQueueLock lock];
    [writeQueue release]; writeQueue = nil;
    [writeQueueLock unlock];
    [writeQueueLock release]; writeQueueLock = nil;
    [queue release]; queue = nil;
	[super dealloc];
}

- (void)setPurgeStrategy:(RMCachePurgeStrategy)theStrategy
{
	purgeStrategy = theStrategy;
}

- (void)setCapacity:(NSUInteger)theCapacity
{
	capacity = theCapacity;
}

- (void)setMinimalPurge:(NSUInteger)theMinimalPurge
{
	minimalPurge = theMinimalPurge;
}

- (UIImage *)cachedImage:(RMTile)tile withCacheKey:(NSString *)aCacheKey
{
//	RMLog(@"DB cache check for tile %d %d %d", tile.x, tile.y, tile.zoom);

    __block UIImage *cachedImage = nil;

    [writeQueueLock lock];

    [queue inDatabase:^(FMDatabase *db)
     {
         FMResultSet *results = [db executeQuery:@"SELECT data FROM ZCACHE WHERE tile_hash = ? AND cache_key = ?", [RMTileCache tileHash:tile], aCacheKey];

         if ([db hadError])
         {
             RMLog(@"DB error while fetching tile data: %@", [db lastErrorMessage]);
             return;
         }

         NSData *data = nil;

         if ([results next])
         {
             data = [results dataForColumnIndex:0];
             if (data) cachedImage = [UIImage imageWithData:data];
         }

         [results close];
     }];

    [writeQueueLock unlock];

    if (capacity != 0 && purgeStrategy == RMCachePurgeStrategyLRU)
        [self touchTile:tile withKey:aCacheKey];

//    RMLog(@"DB cache     hit    tile %d %d %d (%@)", tile.x, tile.y, tile.zoom, [RMTileCache tileHash:tile]);

	return cachedImage;
}

- (void)addImage:(UIImage *)image forTile:(RMTile)tile withCacheKey:(NSString *)aCacheKey
{
    // TODO: Converting the image here (again) is not so good...
	NSData *data = UIImagePNGRepresentation(image);

    if (capacity != 0)
    {
        NSUInteger tilesInDb = [self count];

        if (capacity <= tilesInDb)
            [self purgeTiles:MAX(minimalPurge, 1+tilesInDb-capacity)];

//        RMLog(@"DB cache     insert tile %d %d %d (%@)", tile.x, tile.y, tile.zoom, [RMTileCache tileHash:tile]);

        // Don't add new images to the database while there are still more than kWriteQueueLimit
        // insert operations pending. This prevents some memory issues.

        BOOL skipThisTile = NO;

        [writeQueueLock lock];

        if ([writeQueue operationCount] > kWriteQueueLimit)
            skipThisTile = YES;

        [writeQueueLock unlock];

        if (skipThisTile)
            return;

        [writeQueue addOperationWithBlock:^{
            __block BOOL result = NO;

            [writeQueueLock lock];

            [queue inDatabase:^(FMDatabase *db)
             {
                 result = [db executeUpdate:@"INSERT OR IGNORE INTO ZCACHE (tile_hash, cache_key, last_used, data) VALUES (?, ?, ?, ?)", [RMTileCache tileHash:tile], aCacheKey, [NSDate date], data];
             }];

            [writeQueueLock unlock];

            if (result == NO)
                RMLog(@"Error occured adding data");
            else
                tileCount++;
        }];
	}
}

#pragma mark -

- (NSUInteger)count
{
    return tileCount;
}

- (NSUInteger)countTiles
{
	__block NSUInteger count = 0;

    [writeQueueLock lock];

    [queue inDatabase:^(FMDatabase *db)
     {
         FMResultSet *results = [db executeQuery:@"SELECT COUNT(tile_hash) FROM ZCACHE"];

         if ([results next])
             count = [results intForColumnIndex:0];
         else
             RMLog(@"Unable to count columns");

         [results close];
     }];

    [writeQueueLock unlock];

	return count;
}

- (void)purgeTiles:(NSUInteger)count
{
    RMLog(@"purging %u old tiles from the db cache", count);

    [writeQueueLock lock];

    [queue inDatabase:^(FMDatabase *db)
     {
         BOOL result = [db executeUpdate:@"DELETE FROM ZCACHE WHERE tile_hash IN (SELECT tile_hash FROM ZCACHE ORDER BY last_used LIMIT ?)", [NSNumber numberWithUnsignedInt:count]];

         if (result == NO)
             RMLog(@"Error purging cache");

         [[db executeQuery:@"VACUUM"] close];
     }];

    [writeQueueLock unlock];

    tileCount = [self countTiles];
}

- (void)removeAllCachedImages 
{
    RMLog(@"removing all tiles from the db cache");

    [writeQueue addOperationWithBlock:^{
        [writeQueueLock lock];

        [queue inDatabase:^(FMDatabase *db)
         {
             BOOL result = [db executeUpdate:@"DELETE FROM ZCACHE"];

             if (result == NO)
                 RMLog(@"Error purging cache");

             [[db executeQuery:@"VACUUM"] close];
         }];

        [writeQueueLock unlock];

        tileCount = [self countTiles];
    }];
}

- (void)touchTile:(RMTile)tile withKey:(NSString *)cacheKey
{
    [writeQueue addOperationWithBlock:^{
        [writeQueueLock lock];

        [queue inDatabase:^(FMDatabase *db)
         {
             BOOL result = [db executeUpdate:@"UPDATE ZCACHE SET last_used = ? WHERE tile_hash = ? AND cache_key = ?", [NSDate date], [RMTileCache tileHash:tile], cacheKey];

             if (result == NO)
                 RMLog(@"Error touching tile");
         }];

        [writeQueueLock unlock];
    }];
}

- (void)didReceiveMemoryWarning
{
    RMLog(@"Low memory in the database tilecache");

    [writeQueueLock lock];
    [writeQueue cancelAllOperations];
    [writeQueueLock unlock];
}

@end
