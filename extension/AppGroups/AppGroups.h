// What AppGroups.m and Keychain.m share inside the one sideload shim dylib.
#import <Foundation/Foundation.h>
#import <os/log.h>

extern os_log_t SGShimLog;
// A string or array entitlement of this process, nil when it has none.
id SGShimEntitlement(NSString *name);
// The container of the App Group the app and each of its extensions agree on (the first one entitled,
// sorted), which is where every group they lack is kept. nil when the process has no group at all.
NSURL *SGShimHostContainer(void);
// Keychain.m: SecItem calls naming a keychain group the signature lacks, taken over. Called once from
// the shim's constructor.
void SGShimKeychainInit(void);
