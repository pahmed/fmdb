#import "FMDatabase.h"
#import "unistd.h"

@implementation CBL_FMDatabase
@synthesize inTransaction;
@synthesize cachedStatements;
@synthesize logsErrors;
@synthesize crashOnErrors;
@synthesize busyRetryTimeout;
@synthesize checkedOut;
@synthesize traceExecution;

// If nonzero, every newly-compiled query will have its query plan explained to the console.
// This is obviously for development use only!
#define EXPLAIN_EVERYTHING 0

// Number of _microseconds_ to wait between attempts to retry a query when the db is busy/locked.
#define RETRY_DELAY_MICROSEC 20000

+ (id)databaseWithPath:(NSString*)aPath {
    return [[[self alloc] initWithPath:aPath] autorelease];
}

- (id)initWithPath:(NSString*)aPath {
    self = [super init];
    
    if (self) {
        databasePath        = [aPath copy];
        openResultSets      = [[NSMutableSet alloc] init];
        db                  = 0x00;
        logsErrors          = 0x00;
        crashOnErrors       = 0x00;
        busyRetryTimeout    = 0.0;
    }
    
    return self;
}

- (void)finalize {
    [self close];
    [super finalize];
}

- (void)dealloc {
    [self close];
    
    [openResultSets release];
    [cachedStatements release];
    [databasePath release];
    
    [super dealloc];
}

+ (NSString*)sqliteLibVersion {
    return [NSString stringWithFormat:@"%s", sqlite3_libversion()];
}

- (NSString *)databasePath {
    return databasePath;
}

- (sqlite3*)sqliteHandle {
    return db;
}

#if 0
- (BOOL)open {
    if (db) {
        return YES;
    }
    
    int err = sqlite3_open((databasePath ? [databasePath fileSystemRepresentation] : ":memory:"), &db );
    if(err != SQLITE_OK) {
        NSLog(@"error opening!: %d", err);
        return NO;
    }
    if (busyRetryTimeout > 0.0) {
        sqlite3_busy_timeout(db, (int)(busyRetryTimeout * 1000));
    }
    
    return YES;
}
#endif

#if SQLITE_VERSION_NUMBER >= 3005000
- (BOOL)openWithFlags:(int)flags {
    if ((flags & SQLITE_OPEN_SHAREDCACHE) && (flags & SQLITE_OPEN_READONLY)) {
        // Multiple shared-cache connections to a db file all seem to inherit the writeability of
        // the first connection, meaning that the READONLY flag doesn't work properly. So I'll need
        // to manage the read-only checks myself.
        flags &= ~SQLITE_OPEN_READONLY;
        flags |= SQLITE_OPEN_READWRITE;
        enforceReadOnly = YES;
    }
    int err = sqlite3_open_v2((databasePath ? [databasePath fileSystemRepresentation] : ":memory:"), &db, flags, NULL /* Name of VFS module to use */);
    if(err != SQLITE_OK) {
        NSLog(@"error opening!: %d", err);
        return NO;
    }
    if (busyRetryTimeout > 0.0) {
        sqlite3_busy_timeout(db, (int)(busyRetryTimeout * 1000));
    }
    return YES;
}
#endif


- (BOOL)close {
    
    [self clearCachedStatements];
    [self closeOpenResultSets];
    
    if (!db) {
        return YES;
    }
    
    int  rc;
    BOOL retry;
    BOOL triedFinalizingOpenStatements = NO;
    
    do {
        retry   = NO;
        rc      = sqlite3_close(db);
        if (SQLITE_BUSY == rc || SQLITE_LOCKED == rc) {
            if (!triedFinalizingOpenStatements) {
                triedFinalizingOpenStatements = YES;
                sqlite3_stmt *pStmt;
                while ((pStmt = sqlite3_next_stmt(db, 0x00)) !=0) {
                    NSLog(@"Closing leaked statement");
                    sqlite3_finalize(pStmt);
                    retry = YES;
                }
            }
        }
        else if (SQLITE_OK != rc) {
            NSLog(@"error closing!: %d", rc);
        }
    }
    while (retry);
    
    db = NULL;
    return YES;
}

- (void) setBusyRetryTimeout:(NSTimeInterval)timeout {
    busyRetryTimeout = timeout;
    if (db) {
        sqlite3_busy_timeout(db, (int)(timeout * 1000));
    }
}

- (NSTimeInterval) busyRetryTimeout {
    return busyRetryTimeout;
}

- (void)clearCachedStatements {
    
    NSEnumerator *e = [cachedStatements objectEnumerator];
    CBL_FMStatement *cachedStmt;

    while ((cachedStmt = [e nextObject])) {
        [cachedStmt close];
    }
    
    [cachedStatements removeAllObjects];
}

- (void)closeOpenResultSets {
    //Copy the set so we don't get mutation errors
    NSSet *resultSets = [[openResultSets copy] autorelease];
    
    NSEnumerator *e = [resultSets objectEnumerator];
    NSValue *returnedResultSet = nil;
    
    while((returnedResultSet = [e nextObject])) {
        CBL_FMResultSet *rs = (CBL_FMResultSet *)[returnedResultSet pointerValue];
        if ([rs respondsToSelector:@selector(close)]) {
            [rs close];
        }
    }
}

- (void)resultSetDidClose:(CBL_FMResultSet *)resultSet {
    NSValue *setValue = [NSValue valueWithNonretainedObject:resultSet];
    [openResultSets removeObject:setValue];
}

/** Returns a list of SQL queries that still have open result sets.
    This is handy to call when debugging a problem where e.g. you can't close or vacuum the
    database because queries are still in progress, and you can't figure out which FMResultSet
    you forgot to close. */
- (NSArray*) openResultSetQueries {
    if (openResultSets.count == 0)
        return nil;
    NSMutableArray* queries = [NSMutableArray array];
    for (NSValue* setValue in openResultSets) {
        CBL_FMResultSet* resultSet = (CBL_FMResultSet*) [setValue pointerValue];
        [queries addObject: [resultSet query]];
    }
    return queries;
}

- (CBL_FMStatement*)cachedStatementForQuery:(NSString*)query {
    return [cachedStatements objectForKey:query];
}

- (void)setCachedStatement:(CBL_FMStatement*)statement forQuery:(NSString*)query {
    query = [query copy]; // in case we got handed in a mutable string...
    [statement setQuery:query];
    [cachedStatements setObject:statement forKey:query];
    [query release];
}


#ifdef SQLITE_HAS_CODEC
- (BOOL)rekey:(NSString*)key {
    if (!key) {
        return NO;
    }
    
    int rc = sqlite3_rekey(db, [key UTF8String], (int)strlen([key UTF8String]));
    
    if (rc != SQLITE_OK) {
        NSLog(@"error on rekey: %d", rc);
        NSLog(@"%@", [self lastErrorMessage]);
    }
    
    return (rc == SQLITE_OK);
}

- (BOOL)setKey:(NSString*)key {
    if (!key) {
        return NO;
    }
    
    int rc = sqlite3_key(db, [key UTF8String], (int)strlen([key UTF8String]));
    
    return (rc == SQLITE_OK);
}
#endif // SQLITE_HAS_CODEC

#if 0
- (BOOL)goodConnection {
    
    if (!db) {
        return NO;
    }
    
    FMResultSet *rs = [self executeQuery:@"select name from sqlite_master where type='table'"];
    
    if (rs) {
        [rs close];
        return YES;
    }
    
    return NO;
}
#endif

- (void)warnInUse {
    NSLog(@"The FMDatabase %@ is currently in use.", self);
    
#ifndef NS_BLOCK_ASSERTIONS
    if (crashOnErrors) {
        NSAssert1(false, @"The FMDatabase %@ is currently in use.", self);
    }
#endif
}

- (BOOL)databaseExists {
    
    if (!db) {
            
        NSLog(@"The FMDatabase %@ is not open.", self);
        
    #ifndef NS_BLOCK_ASSERTIONS
        if (crashOnErrors) {
            NSAssert1(false, @"The FMDatabase %@ is not open.", self);
        }
    #endif
        
        return NO;
    }
    
    return YES;
}

- (NSString*)lastErrorMessage {
    return [NSString stringWithUTF8String:sqlite3_errmsg(db)];
}

- (BOOL)hadError {
    int lastErrCode = [self lastErrorCode];
    
    return (lastErrCode > SQLITE_OK && lastErrCode < SQLITE_ROW);
}

- (int)lastErrorCode {
    return sqlite3_errcode(db);
}

- (sqlite_int64)lastInsertRowId {
    
    if (inUse) {
        [self warnInUse];
        return NO;
    }
    [self setInUse:YES];
    
    sqlite_int64 ret = sqlite3_last_insert_rowid(db);
    
    [self setInUse:NO];
    
    return ret;
}

- (int)changes {
    if (inUse) {
        [self warnInUse];
        return 0;
    }
    
    [self setInUse:YES];
    int ret = sqlite3_changes(db);
    [self setInUse:NO];
    
    return ret;
}

static int bindNSString(sqlite3_stmt *pStmt, int idx, NSString *str) {
    // First attempt: Get a C string directly from the CFString if it's in the right format:
    const char* cstr = CFStringGetCStringPtr((CFStringRef)str, kCFStringEncodingUTF8);
    if (cstr) {
        size_t len = strlen(cstr);
        return sqlite3_bind_text(pStmt, idx, cstr, (int)len, SQLITE_TRANSIENT);
    }
    NSUInteger len;
    NSUInteger maxLen = [str maximumLengthOfBytesUsingEncoding: NSUTF8StringEncoding];
    char* buf = malloc(maxLen);
    if (!buf)
        return SQLITE_NOMEM;
    if (![str getBytes: buf maxLength: maxLen usedLength: &len encoding: NSUTF8StringEncoding
               options: 0 range: NSMakeRange(0, str.length) remainingRange: NULL]) {
        free(buf);
        return SQLITE_MISUSE;
    }
    return sqlite3_bind_text(pStmt, idx, buf, (int)len, &free);
}

- (void)bindObject:(id)obj toColumn:(int)idx inStatement:(sqlite3_stmt*)pStmt {
    // FIXME - someday check the return codes on these binds.
    
    if ([obj isKindOfClass:[NSNumber class]]) {
        const char* objCType = [obj objCType];
        if (strcmp(objCType, @encode(BOOL)) == 0) {
            sqlite3_bind_int(pStmt, idx, ([obj boolValue] ? 1 : 0));
        }
        else if (strcmp(objCType, @encode(int)) == 0) {
            sqlite3_bind_int64(pStmt, idx, [obj longValue]);
        }
        else if (strcmp(objCType, @encode(long)) == 0) {
            sqlite3_bind_int64(pStmt, idx, [obj longValue]);
        }
        else if (strcmp(objCType, @encode(long long)) == 0) {
            sqlite3_bind_int64(pStmt, idx, [obj longLongValue]);
        }
        else if (strcmp(objCType, @encode(float)) == 0) {
            sqlite3_bind_double(pStmt, idx, [obj floatValue]);
        }
        else if (strcmp(objCType, @encode(double)) == 0) {
            sqlite3_bind_double(pStmt, idx, [obj doubleValue]);
        }
        else {
            bindNSString(pStmt, idx, [obj description]);
        }
    }
    else if ([obj isKindOfClass:[NSString class]]) {
        bindNSString(pStmt, idx, obj);
    }
    else if ([obj isKindOfClass:[NSData class]]) {
        const void* bytes = [obj bytes];
        if (bytes) {
            sqlite3_bind_blob(pStmt, idx, bytes, (int)[obj length], SQLITE_TRANSIENT);
        } else {
            // it's an empty NSData object, aka [NSData data].
            // Don't pass a NULL pointer, or sqlite will bind a SQL null instead of a blob!
            sqlite3_bind_blob(pStmt, idx, "", 0, SQLITE_STATIC);
        }
    }
    else if ([obj isKindOfClass:[NSDate class]]) {
        sqlite3_bind_double(pStmt, idx, [obj timeIntervalSince1970]);
    }
    else if ((!obj) || ((NSNull *)obj == [NSNull null])) {
        sqlite3_bind_null(pStmt, idx);
    }
    else {
        bindNSString(pStmt, idx, [obj description]);
    }
}

#ifdef ENABLE_FORMATTED_QUERY
- (void)_extractSQL:(NSString *)sql argumentsList:(va_list)args intoString:(NSMutableString *)cleanedSQL arguments:(NSMutableArray *)arguments {
    
    NSUInteger length = [sql length];
    unichar last = '\0';
    for (NSUInteger i = 0; i < length; ++i) {
        id arg = nil;
        unichar current = [sql characterAtIndex:i];
        unichar add = current;
        if (last == '%') {
            switch (current) {
                case '@':
                    arg = va_arg(args, id); break;
                case 'c':
                    arg = [NSString stringWithFormat:@"%c", va_arg(args, int)]; break;
                case 's':
                    arg = [NSString stringWithUTF8String:va_arg(args, char*)]; break;
                case 'd':
                case 'D':
                case 'i':
                    arg = [NSNumber numberWithInt:va_arg(args, int)]; break;
                case 'u':
                case 'U':
                    arg = [NSNumber numberWithUnsignedInt:va_arg(args, unsigned int)]; break;
                case 'h':
                    i++;
                    if (i < length && [sql characterAtIndex:i] == 'i') {
                        arg = [NSNumber numberWithInt:va_arg(args, int)];
                    }
                    else if (i < length && [sql characterAtIndex:i] == 'u') {
                        arg = [NSNumber numberWithInt:va_arg(args, int)];
                    }
                    else {
                        i--;
                    }
                    break;
                case 'q':
                    i++;
                    if (i < length && [sql characterAtIndex:i] == 'i') {
                        arg = [NSNumber numberWithLongLong:va_arg(args, long long)];
                    }
                    else if (i < length && [sql characterAtIndex:i] == 'u') {
                        arg = [NSNumber numberWithUnsignedLongLong:va_arg(args, unsigned long long)];
                    }
                    else {
                        i--;
                    }
                    break;
                case 'f':
                    arg = [NSNumber numberWithDouble:va_arg(args, double)]; break;
                case 'g':
                    arg = [NSNumber numberWithDouble:va_arg(args, double)]; break;
                case 'l':
                    i++;
                    if (i < length) {
                        unichar next = [sql characterAtIndex:i];
                        if (next == 'l') {
                            i++;
                            if (i < length && [sql characterAtIndex:i] == 'd') {
                                //%lld
                                arg = [NSNumber numberWithLongLong:va_arg(args, long long)];
                            }
                            else if (i < length && [sql characterAtIndex:i] == 'u') {
                                //%llu
                                arg = [NSNumber numberWithUnsignedLongLong:va_arg(args, unsigned long long)];
                            }
                            else {
                                i--;
                            }
                        }
                        else if (next == 'd') {
                            //%ld
                            arg = [NSNumber numberWithLong:va_arg(args, long)];
                        }
                        else if (next == 'u') {
                            //%lu
                            arg = [NSNumber numberWithUnsignedLong:va_arg(args, unsigned long)];
                        }
                        else {
                            i--;
                        }
                    }
                    else {
                        i--;
                    }
                    break;
                default:
                    // something else that we can't interpret. just pass it on through like normal
                    break;
            }
        }
        else if (current == '%') {
            // percent sign; skip this character
            add = '\0';
        }
        
        if (arg != nil) {
            [cleanedSQL appendString:@"?"];
            [arguments addObject:arg];
        }
        else if (add != '\0') {
            [cleanedSQL appendFormat:@"%C", add];
        }
        last = current;
    }
    
}
#endif // ENABLE_FORMATTED_QUERY

- (CBL_FMResultSet *)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray*)arrayArgs orVAList:(va_list)args {
    
    if (![self databaseExists]) {
        return 0x00;
    }
    
    if (inUse) {
        [self warnInUse];
        return 0x00;
    }
    
    [self setInUse:YES];
    
    CBL_FMResultSet *rs = nil;
    
    int rc                  = 0x00;
    sqlite3_stmt *pStmt     = 0x00;
    CBL_FMStatement *statement  = 0x00;
    
    if (traceExecution && sql) {
        NSLog(@"%@ executeQuery: %@", self, sql);
    }
    
    if (shouldCacheStatements) {
        statement = [self cachedStatementForQuery:sql];
        pStmt = statement ? [statement statement] : 0x00;
    }

    if (!pStmt) {
        rc = sqlite3_prepare_v2(db, [sql UTF8String], -1, &pStmt, 0);

        if (enforceReadOnly && SQLITE_OK == rc && !sqlite3_stmt_readonly(pStmt)) {
            //FIX: Somehow set sqlite3_errcode to SQLITE_READONLY so clients see it!
            rc = SQLITE_READONLY;
        }

        if (SQLITE_OK != rc) {
            if (logsErrors) {
                NSLog(@"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
                NSLog(@"DB Query: %@", sql);
#ifndef NS_BLOCK_ASSERTIONS
                if (crashOnErrors) {
                    NSAssert2(false, @"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
                }
#endif
            }
            
            sqlite3_finalize(pStmt);
            
            [self setInUse:NO];
            return nil;
        }

#if EXPLAIN_EVERYTHING
        if (shouldCacheStatements && pStmt) {
            NSLog(@"$$$ Caching SQL query: %@\n%@",
                  [sql stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]],
                  [FMStatement explainQueryPlan: pStmt]);
        }
#endif
}

    id obj;
    int idx = 0;
    int queryCount = sqlite3_bind_parameter_count(pStmt); // pointed out by Dominic Yu (thanks!)
    
    while (idx < queryCount) {
        
        if (arrayArgs) {
            obj = [arrayArgs objectAtIndex:idx];
        }
        else {
            obj = va_arg(args, id);
        }
        
        if (traceExecution) {
            NSLog(@"obj: %@", obj);
        }
        
        idx++;
        
        [self bindObject:obj toColumn:idx inStatement:pStmt];
    }
    
    if (idx != queryCount) {
        NSLog(@"Error: the bind count is not correct for the # of variables (executeQuery)");
        sqlite3_finalize(pStmt);
        [self setInUse:NO];
        return nil;
    }
    
    [statement retain]; // to balance the release below
    
    if (!statement) {
        statement = [[CBL_FMStatement alloc] init];
        [statement setStatement:pStmt];
        
        if (shouldCacheStatements) {
            [self setCachedStatement:statement forQuery:sql];
        }
    }
    
    // the statement gets closed in rs's dealloc or [rs close];
    rs = [CBL_FMResultSet resultSetWithStatement:statement usingParentDatabase:self];
    [rs setQuery:sql];
    NSValue *openResultSet = [NSValue valueWithNonretainedObject:rs];
    [openResultSets addObject:openResultSet];
    
    statement.useCount = statement.useCount + 1;
    
    [statement release];    
    
    [self setInUse:NO];
    
    return rs;
}

- (CBL_FMResultSet *)executeQuery:(NSString*)sql, ... {
    va_list args;
    va_start(args, sql);
    
    id result = [self executeQuery:sql withArgumentsInArray:nil orVAList:args];
    
    va_end(args);
    return result;
}

#ifdef ENABLE_FORMATTED_QUERY
- (FMResultSet *)executeQueryWithFormat:(NSString*)format, ... {
    va_list args;
    va_start(args, format);
    
    NSMutableString *sql = [NSMutableString stringWithCapacity:[format length]];
    NSMutableArray *arguments = [NSMutableArray array];
    [self _extractSQL:format argumentsList:args intoString:sql arguments:arguments];    
    
    va_end(args);
    
    return [self executeQuery:sql withArgumentsInArray:arguments];
}
#endif // ENABLE_FORMATTED_QUERY

- (CBL_FMResultSet *)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray *)arguments {
    return [self executeQuery:sql withArgumentsInArray:arguments orVAList:NULL];
}

- (BOOL)executeUpdate:(NSString*)sql error:(NSError**)outErr withArgumentsInArray:(NSArray*)arrayArgs orVAList:(va_list)args {
    
    if (![self databaseExists]) {
        return NO;
    }
    
    if (inUse) {
        [self warnInUse];
        return NO;
    }
    
    [self setInUse:YES];
    
    int rc                   = 0x00;
    sqlite3_stmt *pStmt      = 0x00;
    CBL_FMStatement *cachedStmt  = 0x00;
    
    if (traceExecution && sql) {
        NSLog(@"%@ executeUpdate: %@", self, sql);
    }
    
    if (shouldCacheStatements) {
        cachedStmt = [self cachedStatementForQuery:sql];
        pStmt = cachedStmt ? [cachedStmt statement] : 0x00;
    }

    if (!pStmt) {
        
        rc      = sqlite3_prepare_v2(db, [sql UTF8String], -1, &pStmt, 0);
        if (SQLITE_OK != rc) {
            if (logsErrors) {
                NSLog(@"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
                NSLog(@"DB Query: %@", sql);
#ifndef NS_BLOCK_ASSERTIONS
                if (crashOnErrors) {
                    NSAssert2(false, @"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
                }
#endif
            }
            
            sqlite3_finalize(pStmt);
            [self setInUse:NO];
            
            if (outErr) {
                *outErr = [NSError errorWithDomain:[NSString stringWithUTF8String:sqlite3_errmsg(db)] code:rc userInfo:nil];
            }
            
            return NO;
        }

#if EXPLAIN_EVERYTHING
        if (shouldCacheStatements && pStmt) {
            NSLog(@"$$$ Caching SQL query: %@\n%@",
                  [sql stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]],
                  [FMStatement explainQueryPlan: pStmt]);
        }
#endif
    }
    
    
    id obj;
    int idx = 0;
    int queryCount = sqlite3_bind_parameter_count(pStmt);
    
    while (idx < queryCount) {
        
        if (arrayArgs) {
            obj = [arrayArgs objectAtIndex:idx];
        }
        else {
            obj = va_arg(args, id);
        }
        
        
        if (traceExecution) {
            NSLog(@"obj: %@", obj);
        }
        
        idx++;
        
        [self bindObject:obj toColumn:idx inStatement:pStmt];
    }
    
    if (idx != queryCount) {
        NSLog(@"Error: the bind count is not correct for the # of variables (%@) (executeUpdate)", sql);
        sqlite3_finalize(pStmt);
        [self setInUse:NO];
        return NO;
    }
    
    /* Call sqlite3_step() to run the virtual machine. Since the SQL being
     ** executed is not a SELECT statement, we assume no data will be returned.
     */
    if (enforceReadOnly && !sqlite3_stmt_readonly(pStmt)) {
        //FIX: Somehow set sqlite3_errcode to SQLITE_READONLY so clients see it!
        rc = SQLITE_READONLY;
    } else {
        rc = sqlite3_step(pStmt);
    }

    if (SQLITE_BUSY == rc || SQLITE_LOCKED == rc) {
        NSLog(@"%s:%d Database busy (%@)", __FUNCTION__, __LINE__, [self databasePath]);
        NSLog(@"Database busy");
    }
    else if (SQLITE_DONE == rc || SQLITE_ROW == rc) {
        // all is well, let's return.
        rc = SQLITE_OK;
    }
    else if (SQLITE_CONSTRAINT == rc) {
        // Constraint violation; not ok, but no need to log about it.
    }
    else if (SQLITE_ERROR == rc) {
        rc = sqlite3_reset(pStmt);  // Get the real error code & message
        NSLog(@"Error calling sqlite3_step (%d: %s) SQLITE_ERROR", rc, sqlite3_errmsg(db));
        NSLog(@"DB Query: %@", sql);
    }
    else if (SQLITE_MISUSE == rc) {
        // uh oh.
        NSLog(@"Error calling sqlite3_step (%d: %s) SQLITE_MISUSE", rc, sqlite3_errmsg(db));
        NSLog(@"DB Query: %@", sql);
    }
    else {
        // wtf?
        NSLog(@"Unknown error calling sqlite3_step (%d: %s) eu", rc, sqlite3_errmsg(db));
        NSLog(@"DB Query: %@", sql);
    }

    
    if (shouldCacheStatements && !cachedStmt) {
        cachedStmt = [[CBL_FMStatement alloc] init];
        
        [cachedStmt setStatement:pStmt];
        
        [self setCachedStatement:cachedStmt forQuery:sql];
        
        [cachedStmt release];
    }

    int rcCleanup;
    if (cachedStmt) {
        cachedStmt.useCount = cachedStmt.useCount + 1;
        rcCleanup = sqlite3_reset(pStmt);
    }
    else {
        /* Finalize the virtual machine. This releases all memory and other
         ** resources allocated by the sqlite3_prepare() call above.
         */
        rcCleanup = sqlite3_finalize(pStmt);
    }
    if (rc == SQLITE_OK)
        rc = rcCleanup;

    [self setInUse:NO];
    
    return (rc == SQLITE_OK);
}


- (BOOL)executeUpdate:(NSString*)sql, ... {
    va_list args;
    va_start(args, sql);
    
    BOOL result = [self executeUpdate:sql error:NULL withArgumentsInArray:nil orVAList:args];
    
    va_end(args);
    return result;
}



- (BOOL)executeUpdate:(NSString*)sql withArgumentsInArray:(NSArray *)arguments {
    return [self executeUpdate:sql error:NULL withArgumentsInArray:arguments orVAList:NULL];
}

#ifdef ENABLE_FORMATTED_QUERY
- (BOOL)executeUpdateWithFormat:(NSString*)format, ... {
    va_list args;
    va_start(args, format);
    
    NSMutableString *sql = [NSMutableString stringWithCapacity:[format length]];
    NSMutableArray *arguments = [NSMutableArray array];
    [self _extractSQL:format argumentsList:args intoString:sql arguments:arguments];    
    
    va_end(args);
    
    return [self executeUpdate:sql withArgumentsInArray:arguments];
}
#endif // ENABLE_FORMATTED_QUERY

#if 0 // unused in CBL --jens
- (BOOL)update:(NSString*)sql error:(NSError**)outErr bind:(id)bindArgs, ... {
    va_list args;
    va_start(args, bindArgs);
    
    BOOL result = [self executeUpdate:sql error:outErr withArgumentsInArray:nil orVAList:args];
    
    va_end(args);
    return result;
}

- (BOOL)rollback {
    BOOL b = [self executeUpdate:@"ROLLBACK TRANSACTION;"];
    if (b) {
        inTransaction = NO;
    }
    return b;
}

- (BOOL)commit {
    BOOL b =  [self executeUpdate:@"COMMIT TRANSACTION;"];
    if (b) {
        inTransaction = NO;
    }
    return b;
}

- (BOOL)beginDeferredTransaction {
    BOOL b =  [self executeUpdate:@"BEGIN DEFERRED TRANSACTION;"];
    if (b) {
        inTransaction = YES;
    }
    return b;
}

- (BOOL)beginTransaction {
    BOOL b =  [self executeUpdate:@"BEGIN EXCLUSIVE TRANSACTION;"];
    if (b) {
        inTransaction = YES;
    }
    return b;
}
#endif



- (BOOL)inUse {
    return inUse || inTransaction;
}

- (void)setInUse:(BOOL)b {
    inUse = b;
}


- (BOOL)shouldCacheStatements {
    return shouldCacheStatements;
}

- (void)setShouldCacheStatements:(BOOL)value {
    
    shouldCacheStatements = value;
    
    if (shouldCacheStatements && !cachedStatements) {
        [self setCachedStatements:[NSMutableDictionary dictionary]];
    }

// Took this out. IMHO setting this property to NO should suspend caching, not clear the cache.
// There's already -clearCachedStatements for that. --Jens
//    if (!shouldCacheStatements) {
//        [self setCachedStatements:nil];
//    }
}


+ (BOOL)isThreadSafe {
    // make sure to read the sqlite headers on this guy!
    return sqlite3_threadsafe() != 0;
}

@end



@implementation CBL_FMStatement
@synthesize statement;
@synthesize query;
@synthesize useCount;

- (void)finalize {
    [self close];
    [super finalize];
}

- (void)dealloc {
    [self close];
    [query release];
    [super dealloc];
}

- (void)close {
    if (statement) {
        sqlite3_finalize(statement);
        statement = 0x00;
    }
}

- (void)reset {
    if (statement) {
        sqlite3_reset(statement);
    }
}

- (NSString*)description {
    return [NSString stringWithFormat:@"%@ %ld hit(s) for query %@", [super description], useCount, query];
}


- (NSString*)explainQueryPlan {
    return [[self class] explainQueryPlan: statement];
}

+ (NSString*)explainQueryPlan: (sqlite3_stmt*)statement {
    // Adapted from example at end of http://www.sqlite.org/eqp.html
    const char *zSql;               /* Input SQL */
    char *zExplain;                 /* SQL with EXPLAIN QUERY PLAN prepended */
    sqlite3_stmt *pExplain;         /* Compiled EXPLAIN QUERY PLAN command */
    int rc;                         /* Return code from sqlite3_prepare_v2() */

    zSql = sqlite3_sql(statement);
    if( zSql==0 ) return nil;

    zExplain = sqlite3_mprintf("EXPLAIN QUERY PLAN %s", zSql);
    if( zExplain==0 ) return nil;

    rc = sqlite3_prepare_v2(sqlite3_db_handle(statement), zExplain, -1, &pExplain, 0);
    sqlite3_free(zExplain);
    if( rc!=SQLITE_OK ) return nil;

    NSMutableString* result = [NSMutableString stringWithCapacity: 100];
    while( SQLITE_ROW==sqlite3_step(pExplain) ){
        int iSelectid = sqlite3_column_int(pExplain, 0);
        int iOrder = sqlite3_column_int(pExplain, 1);
        int iFrom = sqlite3_column_int(pExplain, 2);
        const char *zDetail = (const char *)sqlite3_column_text(pExplain, 3);

        if (result.length > 0)
            [result appendString: @"\n"];
        [result appendFormat: @"%d %d %d %s", iSelectid, iOrder, iFrom, zDetail];
    }
    
    sqlite3_finalize(pExplain);
    return result;
}


@end

