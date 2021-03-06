/*
 * Created by Youssef Francis on September 25th, 2012.
 */

#import "GRClient.h"
#include "GRIPCProtocol.h"

#include <mach-o/dyld.h>

@interface GRClient (Private)
+ (BOOL)portIsValid:(CFMessagePortRef)port;
- (NSString*)executableName;
- (CFMessagePortRef)serverPort;
- (CFMessagePortRef)localPort;
- (void)destroyLocalPort;
- (CFDataRef)createMessageWithInfo:(CFDictionaryRef)info;
- (BOOL)sendMessage:(CFDataRef)data;
@end

@protocol GRClientDelegate <NSObject>
+ (void)handleImportFailureWithInfo:(NSDictionary*)info;
+ (void)handleImportSuccessWithInfo:(NSDictionary*)info;
@end

static CFDictionaryRef
createUnwrappedMessage(CFDataRef data)
{
    CFPropertyListRef info = NULL;
    if (data != NULL) {
        info = CFPropertyListCreateWithData(kCFAllocatorDefault,
                                            data,
                                            kCFPropertyListImmutable,
                                            NULL,
                                            NULL);
    }
    return (CFDictionaryRef)info;
}

static CFDataRef 
messageReceived(CFMessagePortRef local,
                SInt32 msgid,
                CFDataRef data,
                void* info)
{    
    Class<GRClientDelegate> delegate = (Class<GRClientDelegate>)info;
    
    switch (msgid) {
        case GREMLIN_SUCCESS: {
                CFDictionaryRef dict = createUnwrappedMessage(data);
                [delegate handleImportSuccessWithInfo:(NSDictionary*)dict];
                if (dict != NULL) 
                    CFRelease(dict);
        } break;
        case GREMLIN_FAILURE: {
                CFDictionaryRef dict = createUnwrappedMessage(data);
                [delegate handleImportFailureWithInfo:(NSDictionary*)dict];
                if (dict != NULL)
                    CFRelease(dict);
        } break;
        default:
            break;
    }

    return NULL;
}

void 
localPortInvalidated(CFMessagePortRef port, void*info)
{
    // deallocate the port once it's been successfully
    // invalidated
    CFRelease(port);
}

void 
serverPortInvalidated(CFMessagePortRef port, void*info)
{
    // looks like the server died (crashed), we should
    // inform the client. since we have no pointer to
    // either the delegate or listener, we should post
    // a notiifcation, and the delegate will handle it
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:@"co.cocoanuts.gremlin.server.crashed"
                      object:nil];
}

@implementation GRClient
@synthesize localPortName = localPortName_;
@synthesize delegate = delegate_;

+ (GRClient*)sharedClient
{
    static dispatch_once_t once;
    static GRClient* sharedClient;
    dispatch_once(&once, ^{
        sharedClient = [[self alloc] init];
    });
    return sharedClient;
}

+ (BOOL)portIsValid:(CFMessagePortRef)port
{
    return (port != NULL &&
            CFMessagePortIsValid(port));
}

- (id)init
{
    self = [super init];
    if (self != nil) {
        // let's set up a name for the local port here
        NSString* bundleID = [[NSBundle mainBundle] bundleIdentifier];

        // our client is not in a bundle, get executable name instead
        if (bundleID == nil)
            bundleID = [self executableName];

        self.localPortName = [bundleID stringByAppendingString:@".gremlin"];
    }
    return self;
}

- (CFDataRef)newMessageWithInfo:(CFDictionaryRef)info
{
    return CFPropertyListCreateXMLData(kCFAllocatorDefault, info);
}

- (NSString*)executableName
{
    char* path = malloc(1024*sizeof(char));
    uint32_t size = 1024;

    if (_NSGetExecutablePath(path, &size) < 0)
        path = realloc(path, size*sizeof(char));

    // assert(path != nil);

    NSString* execPath = [NSString stringWithUTF8String:path];

    free(path);

    return [execPath lastPathComponent];
}

- (void)destroyLocalPort
{
    if (local_port_ != NULL) {
        CFMessagePortInvalidate(local_port_);
        local_port_ = NULL;
    }
}

- (CFMessagePortRef)localPort
{
    if (local_port_ == NULL) {
        CFMessagePortContext context = {0, (void*)delegate_, NULL, NULL, NULL};
        local_port_ = CFMessagePortCreateLocal(NULL,
                                              (CFStringRef)localPortName_,
                                              messageReceived,
                                              &context, 
                                              NULL);
        
        CFMessagePortSetInvalidationCallBack(local_port_, 
                                             localPortInvalidated);
        
        // if rl_source_ already exists, remove it from the runloop
        if (rl_source_ != NULL) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                  rl_source_,
                                  kCFRunLoopDefaultMode);
            CFRelease(rl_source_);
            rl_source_ = NULL;
        }

        rl_source_ = CFMessagePortCreateRunLoopSource(NULL, local_port_, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           rl_source_,
                           kCFRunLoopDefaultMode);
    }

    return local_port_; 
}

- (CFMessagePortRef)serverPort
{
    // check if current server port is valid
    if (![GRClient portIsValid:server_port_]) {
        if (server_port_ != NULL) 
            CFRelease(server_port_);
        
        // if port is invalid/nonexistent we should try once to create it
        const CFStringRef serverPortName = 
            CFSTR(gremlind_MessagePortName);
        server_port_ = CFMessagePortCreateRemote(NULL, serverPortName);
        
        // if this attempt succeeds, set up the port
        if ([GRClient portIsValid:server_port_]) {
            CFMessagePortSetInvalidationCallBack(server_port_,
                                                 serverPortInvalidated);
        }
        else {
            // otherwise clean up and dont retry, if this method
            // returns NULL the caller is to assume that communication
            // is impossible and inform the client of the failure
            if (server_port_ != NULL)
                CFRelease(server_port_);
            server_port_ = NULL;
        }
    }

    return server_port_;
}

- (BOOL)sendMessage:(CFDataRef)msg
{
    CFMessagePortRef port = [self serverPort];
    if (port != NULL) {
        int result = 0;
        result = CFMessagePortSendRequest(port,
                                          GREMLIN_IMPORT,
                                          msg,
                                          5,
                                          5,
                                          kCFRunLoopDefaultMode,
                                          NULL);

        return (result == kCFMessagePortSuccess);
    }

    // if we couldn't get a server port, we should
    // inform the client that this import request
    // has failed
    return NO;
}

- (BOOL)registerForNotifications:(id)delegate
{
    self.delegate = delegate;
    return [GRClient portIsValid:[self localPort]];
}

- (void)unregisterForNotifications
{
    self.delegate = nil;
    [self destroyLocalPort];
}

- (BOOL)sendServerMessage:(NSMutableDictionary*)msgInfo
             haveListener:(BOOL)haveListener
{
    BOOL status = NO;
    if (haveListener == YES) {
        [msgInfo setObject:localPortName_
                    forKey:@"center"];
    }

    CFDataRef msg = [self newMessageWithInfo:(CFDictionaryRef)msgInfo];
    if (msg != NULL) {
        status = [self sendMessage:msg];
        CFRelease(msg);
    }

    return status;
}

- (BOOL)haveGremlin
{
    return [GRClient portIsValid:[self serverPort]];
}

@end

