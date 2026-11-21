#import <Foundation/Foundation.h>
#import <signal.h>
#import "NIPCFrame.h"
#import "NVDaemonServer.h"

static NVDaemonServer *gServer = nil;
static dispatch_source_t gTermSource;

static void handleSignal(int sig) {
    (void)sig;
    if (gTermSource) dispatch_source_merge_data(gTermSource, 1);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *socketPath = @NIPC_SOCKET_PATH;
        for (int i = 1; i < argc - 1; i++) {
            if (strcmp(argv[i], "--socket") == 0) {
                socketPath = [NSString stringWithUTF8String:argv[i + 1]];
            }
        }

        gServer = [NVDaemonServer new];
        NSError *err = nil;
        if (![gServer startOnPath:socketPath error:&err]) {
            fprintf(stderr, "navigatiod: cannot bind %s: %s\n",
                    socketPath.UTF8String, err.localizedDescription.UTF8String);
            return 1;
        }

        gTermSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0,
                                             dispatch_get_main_queue());
        dispatch_source_set_event_handler(gTermSource, ^{
            [gServer stop];
            CFRunLoopStop(CFRunLoopGetMain());
        });
        dispatch_resume(gTermSource);

        signal(SIGTERM, handleSignal);
        signal(SIGINT,  handleSignal);
        signal(SIGPIPE, SIG_IGN);

        CFRunLoopRun();
        return 0;
    }
}
