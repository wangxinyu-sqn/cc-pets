#import <Foundation/Foundation.h>
#import "CCPetsCleanup.h"

int main(void) {
    @autoreleasepool {
        PruneStaleRuntimeState();
    }
    return EXIT_SUCCESS;
}
