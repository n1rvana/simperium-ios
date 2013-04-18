//
//  SPIndexProcessor.m
//  Simperium
//
//  Created by Michael Johnston on 11-11-16.
//  Copyright (c) 2011 Simperium. All rights reserved.
//
//  Processes index data from the Simperium service

#import "Simperium.h"
#import "SPStorage.h"
#import "SPIndexProcessor.h"
#import "SPManagedObject.h"
#import "SPGhost.h"
#import "SPStorage.h"
#import "JSONKit.h"
#import "DDLog.h"
#import "SPBucket.h"
#import "SPDiffable.h"
#import "SPDiffer.h"

static int ddLogLevel = LOG_LEVEL_INFO;

#define kBatchSize 30

@implementation SPIndexProcessor

+ (int)ddLogLevel {
    return ddLogLevel;
}

+ (void)ddSetLogLevel:(int)logLevel {
    ddLogLevel = logLevel;
}

-(id)init
{
    if (self = [super init]) {
    }
    
    return self;
}

-(void)dealloc
{
    [super dealloc];
}

// Process an index of keys from the Simperium service for a particular bucket
-(void)processIndex:(NSArray *)indexArray bucket:(SPBucket *)bucket versionHandler:(void(^)(NSString *key, NSString *version))versionHandler 
{
    id<SPStorageProvider> threadSafeStorage = [bucket.storage threadSafeStorage];
    
    // indexArray could have thousands of items; break it up into batches to manage memory use
    NSMutableDictionary *indexDict = [NSMutableDictionary dictionaryWithCapacity:[indexArray count]];
    NSInteger numBatches = 1 + [indexArray count] / kBatchSize;
    NSMutableArray *batchLists = [NSMutableArray arrayWithCapacity:numBatches];
    for (int i=0; i<numBatches; i++) {
        [batchLists addObject: [NSMutableArray arrayWithCapacity:kBatchSize]];
    }
    
    int currentBatch = 0;
    // Build the batches
    NSMutableArray *currentBatchList = [batchLists objectAtIndex:currentBatch];
    for (NSDictionary *dict in indexArray) {
        NSString *key = [dict objectForKey:@"id"];
        id version = [dict objectForKey:@"v"];
        
        // Map it for convenience
        [indexDict setObject:version forKey:key];
        
        // Put it in a batch (advancing to next batch if necessary)
        [currentBatchList addObject:key];
        if ([currentBatchList count] == kBatchSize) {
            currentBatchList = [batchLists objectAtIndex:++currentBatch];
        }
    }
    
    // Process each batch while being efficient with memory and faulting
    for (NSMutableArray *batchList in batchLists) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        // Batch fault the entities for efficiency
        NSDictionary *objects = [threadSafeStorage faultObjectsForKeys:batchList bucketName:bucket.name];
        
        for (NSString *key in batchList) {
            id version = [indexDict objectForKey: key];
            
            // Store versions as strings, but if they come off the wire as numbers, then handle that too
            if ([version isKindOfClass:[NSNumber class]])
                version = [NSString stringWithFormat:@"%ld", (long)[version integerValue]];
            
            // Check to see if this entity already exists locally and is up to date
            id<SPDiffable> object = [objects objectForKey:key];
            if (object && object.ghost != nil && object.ghost.version != nil && [version isEqualToString:object.ghost.version])
                continue;
            
            // Allow caller to use the key and version
            dispatch_async(dispatch_get_main_queue(), ^{
                versionHandler(key, version);
            });
        }
        
        // Refault to free up the memory
        [threadSafeStorage refaultObjects: [objects allValues]];
        [pool release];
    }
}

// Process actual version data from the Simperium service for a particular bucket
-(void)processVersions:(NSArray *)versions bucket:(SPBucket *)bucket firstSync:(BOOL)firstSync changeHandler:(void(^)(NSString *key))changeHandler
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSMutableSet *addedKeys = [NSMutableSet setWithCapacity:5];
    NSMutableSet *changedKeys = [NSMutableSet setWithCapacity:5];
    id<SPStorageProvider> threadSafeStorage = [bucket.storage threadSafeStorage];
    
    // Batch fault all the objects into a dictionary for efficiency
    NSMutableArray *objectKeys = [NSMutableArray arrayWithCapacity:[versions count]];
    for (NSArray *versionData in versions) {
        [objectKeys addObject:[versionData objectAtIndex:0]];
    }
    NSDictionary *objects = [threadSafeStorage faultObjectsForKeys:objectKeys bucketName:bucket.name];
    
    // Process all version data
    for (NSArray *versionData in versions)
    {
        // Unmarshal the data
        NSString *key = [versionData objectAtIndex:0];
        NSString *responseString = [versionData objectAtIndex:1];
        NSString *version = [versionData objectAtIndex:2];
        NSMutableDictionary *data = [responseString objectFromJSONStringWithParseOptions:JKParseOptionLooseUnicode];
                          
        id<SPDiffable> object = [objects objectForKey:key];
        SPGhost *ghost = nil;
        
        if (!object) {
            // The object doesn't exist locally yet, so create it
            object = [threadSafeStorage insertNewObjectForBucketName:bucket.name simperiumKey:key];
            object.bucket = bucket; // set it manually since it won't be set automatically yet
            [object loadMemberData:data];    
            [addedKeys addObject:key];
                        
            NSMutableDictionary *newMemberData = [[object dictionary] mutableCopy];
            ghost = [[SPGhost alloc] initWithKey:[object simperiumKey] memberData:newMemberData];
            [newMemberData release];
            DDLogVerbose(@"Simperium added object from index (%@): %@", bucket.name, [object simperiumKey]);
        } else {
            // The object already exists locally; update it if necessary
            BOOL overwriteLocalData = NO;
            
            // The firstSync flag is set if there has not yet been a successful sync. In that case, additional checks
            // are performed to see if the local data should be preserved instead. This handles migrations from existing
            // sync systems (e.g. Simplenote GAE), and in particular, cases where there are local, unsynced changes that
            // should be preserved.
            if (firstSync) {
                NSDictionary *diff = [bucket.differ diff:object withDictionary:data];
                if ([diff count] > 0 && [object respondsToSelector:@selector(shouldOverwriteLocalChangesFromIndex)]) {
                    DDLogVerbose(@"Simperium object %@ has changes: %@", [object simperiumKey], diff);
                    if ([object performSelector:@selector(shouldOverwriteLocalChangesFromIndex)]) {
                        // The app has determined this object's local changes should be taken from index regardless of any local changes
                        DDLogVerbose(@"Simperium local object found (%@) with local changes, and OVERWRITING those changes", bucket.name);
                        overwriteLocalData = YES;
                    } else
                        // There's a local, unsynced change, which can only happen on first sync when migrating from an earlier version of an app.
                        // Allow the caller to deal with this case
                        changeHandler(key);
                }
                
                // Set the ghost data (this expects all properties to be present in memberData)
                ghost = [[SPGhost alloc] initWithKey:[object simperiumKey] memberData: data];                
            } else if (object.version != nil && ![version isEqualToString:object.version]) {
                // Safe to do here since the local change has already been posted
                overwriteLocalData = YES;
            }
            
            // Overwrite local changes if necessary
            if (overwriteLocalData) {
                [object loadMemberData:data];
                
                // Be sure to load all members into ghost (since the version results might only contain a subset of members that were changed)
                NSMutableDictionary *ghostMemberData = [[object dictionary] mutableCopy];
                [ghost release]; // might have already been allocated above
                ghost = [[SPGhost alloc] initWithKey:[object simperiumKey] memberData: ghostMemberData];
                [ghostMemberData release];
                [changedKeys addObject:key];
                DDLogVerbose(@"Simperium loaded new data into object %@ (%@)", [object simperiumKey], bucket.name);
            }

        }
        
        // If there is a new/changed ghost, store it
        if (ghost) {
            DDLogVerbose(@"Simperium updating ghost data for object %@ (%@)", [object simperiumKey], bucket.name);
            ghost.version = version;
            object.ghost = ghost;
            object.simperiumKey = object.simperiumKey; // ugly hack to force entity to save since ghost isn't transient
            [ghost release];
        }
    }
    
    // Store after processing the batch for efficiency
    [threadSafeStorage save];
    [threadSafeStorage refaultObjects:[objects allValues]];
    
    // Do all main thread work afterwards as well
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfoAdded = [NSDictionary dictionaryWithObjectsAndKeys:
                                  bucket.name, @"bucketName",
                                  addedKeys, @"keys", nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ProcessorDidAddObjectsNotification" object:bucket userInfo:userInfoAdded];

        NSDictionary *userInfoChanged = [NSDictionary dictionaryWithObjectsAndKeys:
                                       bucket.name, @"bucketName",
                                       changedKeys, @"keys", nil];        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ProcessorDidChangeObjectsNotification" object:bucket userInfo:userInfoChanged];
    });
    
    [pool release];
}

@end