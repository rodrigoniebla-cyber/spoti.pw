// Spotify's keychain groups, kept where the sideload signature can reach them.
//
// Spotify hands its Siri extension the signed in account through the keychain: the app writes the
// credentials into the group 8W66MEA7DD.com.spotify.client.extension-credentials and IntentsExtension
// reads them from there before it asks spclient's siri-proxy to play anything (scripts/inspect-
// extensions.sh shows both entitlements and the group in their code). 8W66MEA7DD is Spotify's App ID
// prefix, which no re-signed IPA has, so the write fails with errSecMissingEntitlement, the read finds
// nothing, and Siri answers "To do that, you'll need to verify your account details in Spotify".
//
// Every SecItem call the app's own code makes (the executable, its frameworks, the extension) is
// rebound here, the fishhook way. A call naming a group the process is entitled to goes through as it
// is. One naming a group it lacks is answered from a small store of our own, a property list per group
// in the App Group container the app and its extensions share (AppGroups.m), so what the app writes
// the extension reads. With no App Group to keep it in, the group is moved onto the signature's own:
// a wildcard keychain group (TEAM.*) takes the same name under the new team, otherwise the call goes to
// the process's default group, which at least keeps the app's own reads working. What goes into the
// store is written there too, and a read the store has nothing for looks there, so an extension signed
// without the App Group still finds the app's items when the two share a wildcard keychain group.
//
// The store is for generic items looked up by their attributes, which is all SPTKeychainManager does
// (dataForDomain:andKey:accessGroup:...). It lives under the container's Library, protected until
// the first unlock like the keychain item it stands in for.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <sys/file.h>
#import <os/log.h>
#import "AppGroups.h"

#define sLog SGShimLog

static NSArray<NSString *> *sKeychainGroups;
static NSString *sApplicationIdentifier;
static NSURL *sStore;

static OSStatus (*sOrigCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*sOrigAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*sOrigUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*sOrigDelete)(CFDictionaryRef);

#pragma mark - which groups are ours

static BOOL Entitled(NSString *group) {
  if ([group isEqualToString:sApplicationIdentifier]) return YES;
  for (NSString *entitled in sKeychainGroups) {
    if ([entitled isEqualToString:group]) return YES;
    if ([entitled hasSuffix:@"*"] && [group hasPrefix:[entitled substringToIndex:entitled.length - 1]]) return YES;
  }
  return NO;
}

// The group a call names, when the process may not use it; nil when the call is left alone.
static NSString *ForeignGroup(CFDictionaryRef query) {
  NSString *group = ((__bridge NSDictionary *)query)[(__bridge NSString *)kSecAttrAccessGroup];
  if (![group isKindOfClass:NSString.class] || !group.length || Entitled(group)) return nil;
  return group;
}

// The same call on a group the signature has, for a process with no App Group to keep a store in.
static NSDictionary *MovedQuery(CFDictionaryRef query, NSString *group) {
  NSMutableDictionary *moved = [(__bridge NSDictionary *)query mutableCopy];
  NSRange dot = [group rangeOfString:@"."];
  NSString *wildcard = nil;
  for (NSString *entitled in sKeychainGroups) {
    if ([entitled hasSuffix:@".*"]) { wildcard = entitled; break; }
  }
  if (wildcard && dot.location != NSNotFound) {
    moved[(__bridge NSString *)kSecAttrAccessGroup] =
        [[wildcard substringToIndex:wildcard.length - 1] stringByAppendingString:[group substringFromIndex:NSMaxRange(dot)]];
  } else {
    [moved removeObjectForKey:(__bridge NSString *)kSecAttrAccessGroup];
  }
  return moved;
}

#pragma mark - the store

// Keys that steer a call rather than describe an item: match options, what to return, how to go about
// it, and the attributes the store has no use for (the group itself, sync, accessibility, access
// control). Their values are the constants' own strings (m_Limit, r_Data, u_AuthUI...).
static BOOL ControlKey(NSString *key) {
  static NSSet<NSString *> *attributes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    attributes = [NSSet setWithObjects:(__bridge NSString *)kSecAttrAccessGroup, (__bridge NSString *)kSecAttrSynchronizable,
                  (__bridge NSString *)kSecAttrAccessible, (__bridge NSString *)kSecAttrAccessControl,
                  (__bridge NSString *)kSecValueData, (__bridge NSString *)kSecValueRef, (__bridge NSString *)kSecValuePersistentRef,
                  (__bridge NSString *)kSecUseDataProtectionKeychain, nil];
  });
  return [key hasPrefix:@"m_"] || [key hasPrefix:@"r_"] || [key hasPrefix:@"u_"] || [attributes containsObject:key];
}

static BOOL PlistValue(id value) {
  return [value isKindOfClass:NSString.class] || [value isKindOfClass:NSData.class] ||
         [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSDate.class];
}

static NSURL *FileFor(NSString *group) {
  NSString *name = [[group stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByAppendingPathExtension:@"plist"];
  return [sStore URLByAppendingPathComponent:name];
}

// Runs `body` on the group's items under a lock the app and its extensions share, writing them back
// when it says so.
static OSStatus WithItems(NSString *group, OSStatus (^body)(NSMutableArray<NSMutableDictionary *> *items, BOOL *changed)) {
  int lock = open([sStore URLByAppendingPathComponent:@".lock"].fileSystemRepresentation, O_RDWR | O_CREAT, 0600);
  if (lock >= 0) flock(lock, LOCK_EX);
  NSURL *file = FileFor(group);
  NSMutableArray<NSMutableDictionary *> *items = [NSMutableArray array];
  NSData *data = [NSData dataWithContentsOfURL:file];
  NSArray *stored = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL] : nil;
  if ([stored isKindOfClass:NSArray.class]) {
    for (id item in stored) {
      if ([item isKindOfClass:NSMutableDictionary.class]) [items addObject:item];
    }
  }
  BOOL changed = NO;
  OSStatus status = body(items, &changed);
  if (changed) {
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:items format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (![out writeToURL:file options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:NULL]) {
      status = errSecIO;
    }
  }
  if (lock >= 0) {
    flock(lock, LOCK_UN);
    close(lock);
  }
  return status;
}

static BOOL Matches(NSDictionary *item, NSDictionary *query) {
  for (NSString *key in query) {
    if (ControlKey(key)) continue;
    id wanted = query[key];
    if (!PlistValue(wanted)) continue;
    if (![item[key] isEqual:wanted]) return NO;
  }
  return YES;
}

static NSArray<NSMutableDictionary *> *Matching(NSArray<NSMutableDictionary *> *items, NSDictionary *query) {
  NSMutableArray *found = [NSMutableArray array];
  for (NSMutableDictionary *item in items) {
    if (Matches(item, query)) [found addObject:item];
  }
  return found;
}

// What one item is handed back as: its data, or its attributes (the data among them when asked).
static id Returned(NSDictionary *item, NSDictionary *query, NSString *group) {
  BOOL data = [query[(__bridge NSString *)kSecReturnData] boolValue];
  BOOL attributes = [query[(__bridge NSString *)kSecReturnAttributes] boolValue] ||
                    [query[(__bridge NSString *)kSecReturnRef] boolValue] || [query[(__bridge NSString *)kSecReturnPersistentRef] boolValue];
  if (data && !attributes) return item[(__bridge NSString *)kSecValueData] ?: [NSData data];
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *key in item) {
    if (![key isEqualToString:(__bridge NSString *)kSecValueData]) out[key] = item[key];
  }
  out[(__bridge NSString *)kSecAttrAccessGroup] = group;
  if (data) out[(__bridge NSString *)kSecValueData] = item[(__bridge NSString *)kSecValueData] ?: [NSData data];
  return out;
}

static BOOL WantsResult(NSDictionary *query) {
  for (NSString *key in query) {
    if ([key hasPrefix:@"r_"] && [query[key] boolValue]) return YES;
  }
  return NO;
}

static OSStatus StoreCopyMatching(NSString *group, NSDictionary *query, CFTypeRef *result) {
  if (result) *result = NULL;
  return WithItems(group, ^OSStatus(NSMutableArray<NSMutableDictionary *> *items, BOOL *changed) {
    NSArray<NSMutableDictionary *> *found = Matching(items, query);
    if (!found.count) return errSecItemNotFound;
    if (!result || !WantsResult(query)) return errSecSuccess;
    id limit = query[(__bridge NSString *)kSecMatchLimit];
    BOOL all = [limit isEqual:(__bridge NSString *)kSecMatchLimitAll] || ([limit isKindOfClass:NSNumber.class] && [limit integerValue] > 1);
    if (all) {
      NSMutableArray *out = [NSMutableArray array];
      NSUInteger most = [limit isKindOfClass:NSNumber.class] ? [limit unsignedIntegerValue] : NSUIntegerMax;
      for (NSDictionary *item in found) {
        if (out.count >= most) break;
        [out addObject:Returned(item, query, group)];
      }
      *result = CFBridgingRetain(out);
    } else {
      *result = CFBridgingRetain(Returned(found.firstObject, query, group));
    }
    return errSecSuccess;
  });
}

static OSStatus StoreAdd(NSString *group, NSDictionary *attributes, CFTypeRef *result) {
  if (result) *result = NULL;
  return WithItems(group, ^OSStatus(NSMutableArray<NSMutableDictionary *> *items, BOOL *changed) {
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    for (NSString *key in attributes) {
      if (!ControlKey(key) && PlistValue(attributes[key])) item[key] = attributes[key];
    }
    // Two items are the same one when their class, service and account agree, as in the keychain.
    NSMutableDictionary *identity = [NSMutableDictionary dictionary];
    for (NSString *key in @[(__bridge NSString *)kSecClass, (__bridge NSString *)kSecAttrService, (__bridge NSString *)kSecAttrAccount]) {
      if (item[key]) identity[key] = item[key];
    }
    if (Matching(items, identity).count) return errSecDuplicateItem;
    id data = attributes[(__bridge NSString *)kSecValueData];
    if ([data isKindOfClass:NSString.class]) data = [data dataUsingEncoding:NSUTF8StringEncoding];
    if ([data isKindOfClass:NSData.class]) item[(__bridge NSString *)kSecValueData] = data;
    NSDate *now = [NSDate date];
    item[(__bridge NSString *)kSecAttrCreationDate] = now;
    item[(__bridge NSString *)kSecAttrModificationDate] = now;
    [items addObject:item];
    *changed = YES;
    if (result && WantsResult(attributes)) *result = CFBridgingRetain(Returned(item, attributes, group));
    return errSecSuccess;
  });
}

static OSStatus StoreUpdate(NSString *group, NSDictionary *query, NSDictionary *update) {
  return WithItems(group, ^OSStatus(NSMutableArray<NSMutableDictionary *> *items, BOOL *changed) {
    NSArray<NSMutableDictionary *> *found = Matching(items, query);
    if (!found.count) return errSecItemNotFound;
    for (NSMutableDictionary *item in found) {
      for (NSString *key in update) {
        id value = update[key];
        if ([key isEqualToString:(__bridge NSString *)kSecValueData]) {
          if ([value isKindOfClass:NSString.class]) value = [value dataUsingEncoding:NSUTF8StringEncoding];
          if ([value isKindOfClass:NSData.class]) item[key] = value;
        } else if (!ControlKey(key) && PlistValue(value)) {
          item[key] = value;
        }
      }
      item[(__bridge NSString *)kSecAttrModificationDate] = [NSDate date];
    }
    *changed = YES;
    return errSecSuccess;
  });
}

static OSStatus StoreDelete(NSString *group, NSDictionary *query) {
  return WithItems(group, ^OSStatus(NSMutableArray<NSMutableDictionary *> *items, BOOL *changed) {
    NSArray<NSMutableDictionary *> *found = Matching(items, query);
    if (!found.count) return errSecItemNotFound;
    [items removeObjectsInArray:found];
    *changed = YES;
    return errSecSuccess;
  });
}

#pragma mark - the calls

static void Note(const char *call, NSString *group, OSStatus status, BOOL stored) {
  os_log(sLog, "[spotifyglass] keychain: %{public}s on %{public}@ %{public}s, %d", call, group,
         stored ? "answered from the shared store" : "moved onto the signature's group", (int)status);
}

// The same write on the signature's own keychain group, for a process that reads there; its outcome
// is the store's to report, not this one's.
static void Mirror(CFDictionaryRef query, NSString *group, CFDictionaryRef update, BOOL add, BOOL remove) {
  NSDictionary *moved = MovedQuery(query, group);
  if (remove) {
    sOrigDelete((__bridge CFDictionaryRef)moved);
  } else if (add) {
    NSMutableDictionary *plain = [moved mutableCopy];
    for (NSString *key in moved) {
      if ([key hasPrefix:@"r_"]) [plain removeObjectForKey:key];
    }
    if (sOrigAdd((__bridge CFDictionaryRef)plain, NULL) == errSecDuplicateItem) {
      NSMutableDictionary *identity = [NSMutableDictionary dictionary];
      NSMutableDictionary *values = [NSMutableDictionary dictionary];
      for (NSString *key in plain) {
        if ([key isEqualToString:(__bridge NSString *)kSecValueData]) values[key] = plain[key];
        else if (!ControlKey(key) || [key isEqualToString:(__bridge NSString *)kSecAttrAccessGroup]) identity[key] = plain[key];
      }
      if (values.count) sOrigUpdate((__bridge CFDictionaryRef)identity, (__bridge CFDictionaryRef)values);
    }
  } else if (update) {
    sOrigUpdate((__bridge CFDictionaryRef)moved, update);
  }
}

static OSStatus SGSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
  NSString *group = query ? ForeignGroup(query) : nil;
  if (!group) return sOrigCopyMatching(query, result);
  if (!sStore) {
    OSStatus status = sOrigCopyMatching((__bridge CFDictionaryRef)MovedQuery(query, group), result);
    Note("read", group, status, NO);
    return status;
  }
  OSStatus status = StoreCopyMatching(group, (__bridge NSDictionary *)query, result);
  if (status == errSecItemNotFound) {
    OSStatus moved = sOrigCopyMatching((__bridge CFDictionaryRef)MovedQuery(query, group), result);
    if (moved == errSecSuccess) {
      Note("read", group, moved, NO);
      return moved;
    }
  }
  Note("read", group, status, YES);
  return status;
}

static OSStatus SGSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
  NSString *group = attributes ? ForeignGroup(attributes) : nil;
  if (!group) return sOrigAdd(attributes, result);
  OSStatus status = sStore ? StoreAdd(group, (__bridge NSDictionary *)attributes, result)
                           : sOrigAdd((__bridge CFDictionaryRef)MovedQuery(attributes, group), result);
  if (sStore && status == errSecSuccess) Mirror(attributes, group, NULL, YES, NO);
  Note("add", group, status, sStore != nil);
  return status;
}

static OSStatus SGSecItemUpdate(CFDictionaryRef query, CFDictionaryRef update) {
  NSString *group = query ? ForeignGroup(query) : nil;
  if (!group) return sOrigUpdate(query, update);
  OSStatus status = sStore ? StoreUpdate(group, (__bridge NSDictionary *)query, (__bridge NSDictionary *)update)
                           : sOrigUpdate((__bridge CFDictionaryRef)MovedQuery(query, group), update);
  if (sStore && status == errSecSuccess) Mirror(query, group, update, NO, NO);
  Note("update", group, status, sStore != nil);
  return status;
}

static OSStatus SGSecItemDelete(CFDictionaryRef query) {
  NSString *group = query ? ForeignGroup(query) : nil;
  if (!group) return sOrigDelete(query);
  OSStatus status = sStore ? StoreDelete(group, (__bridge NSDictionary *)query)
                           : sOrigDelete((__bridge CFDictionaryRef)MovedQuery(query, group));
  if (sStore) Mirror(query, group, NULL, NO, YES);
  Note("delete", group, status, sStore != nil);
  return status;
}

#pragma mark - rebinding

typedef struct {
  const char *name;
  void *replacement;
} SGRebinding;

static const SGRebinding kRebindings[] = {
  {"SecItemCopyMatching", (void *)SGSecItemCopyMatching},
  {"SecItemAdd", (void *)SGSecItemAdd},
  {"SecItemUpdate", (void *)SGSecItemUpdate},
  {"SecItemDelete", (void *)SGSecItemDelete},
};
static const uint32_t kRebindingCount = sizeof(kRebindings) / sizeof(kRebindings[0]);

// Writes one pointer, making its page writable first; a page dyld made read only after binding
// (__DATA_CONST) is copied and made read only again. Tweak's Core/SGRebind.m does the same for the
// executable alone.
static void WriteSlot(void **slot, void *value, BOOL readOnly) {
  vm_size_t page = vm_page_size;
  vm_address_t start = (vm_address_t)slot & ~(page - 1);
  if (vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
  *slot = value;
  if (readOnly) vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ);
}

// Points the image's import slots for the SecItem calls at the ones above, the original kept from the
// first slot met (they all hold the same function).
static void RebindImage(const struct mach_header *mh, intptr_t slide) {
  if (mh->magic != MH_MAGIC_64) return;
  Dl_info info;
  if (!dladdr(mh, &info) || !info.dli_fname) return;
  // Spotify's own code only: the executable, its frameworks and its extensions all live in the bundle.
  // The system's frameworks keep calling the real keychain, and so does this dylib.
  if (!strstr(info.dli_fname, ".app/") || strstr(info.dli_fname, "SpotifyGlassAppGroups")) return;
  const struct mach_header_64 *header = (const struct mach_header_64 *)mh;

  const struct segment_command_64 *linkedit = NULL;
  const struct symtab_command *symtab = NULL;
  const struct dysymtab_command *dysymtab = NULL;
  const struct load_command *command = (const struct load_command *)(header + 1);
  for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
    if (command->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0) {
      linkedit = (const struct segment_command_64 *)command;
    } else if (command->cmd == LC_SYMTAB) {
      symtab = (const struct symtab_command *)command;
    } else if (command->cmd == LC_DYSYMTAB) {
      dysymtab = (const struct dysymtab_command *)command;
    }
  }
  if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return;

  uintptr_t base = (uintptr_t)slide + (uintptr_t)(linkedit->vmaddr - linkedit->fileoff);
  const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
  const char *strings = (const char *)(base + symtab->stroff);
  const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

  command = (const struct load_command *)(header + 1);
  for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
    if (command->cmd != LC_SEGMENT_64) continue;
    const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
    BOOL readOnly = strcmp(segment->segname, "__DATA_CONST") == 0 || strcmp(segment->segname, "__AUTH_CONST") == 0;
    const struct section_64 *section = (const struct section_64 *)(segment + 1);
    for (uint32_t s = 0; s < segment->nsects; s++, section++) {
      uint32_t type = section->flags & SECTION_TYPE;
      if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
      void **slots = (void **)((uintptr_t)slide + section->addr);
      uint64_t count = section->size / sizeof(void *);
      for (uint64_t k = 0; k < count; k++) {
        uint64_t entry = (uint64_t)section->reserved1 + k;
        if (entry >= dysymtab->nindirectsyms) continue;
        uint32_t index = indirect[entry];
        if (index & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS) || index >= symtab->nsyms) continue;
        uint32_t offset = symbols[index].n_un.n_strx;
        if (offset >= symtab->strsize) continue;
        const char *name = strings + offset;
        if (name[0] != '_') continue;
        for (uint32_t r = 0; r < kRebindingCount; r++) {
          if (strcmp(name + 1, kRebindings[r].name) != 0 || slots[k] == kRebindings[r].replacement) continue;
          void *held = slots[k];
          WriteSlot(&slots[k], kRebindings[r].replacement, readOnly);
          void **original = r == 0 ? (void **)&sOrigCopyMatching : r == 1 ? (void **)&sOrigAdd : r == 2 ? (void **)&sOrigUpdate : (void **)&sOrigDelete;
          if (!*original && held) *original = held;
        }
      }
    }
  }
}

void SGShimKeychainInit(void) {
  NSArray *groups = SGShimEntitlement(@"keychain-access-groups");
  sKeychainGroups = [groups isKindOfClass:NSArray.class] ? groups : @[];
  id identifier = SGShimEntitlement(@"application-identifier");
  sApplicationIdentifier = [identifier isKindOfClass:NSString.class] ? identifier : nil;
  // The real calls first, so a slot met before its original is known still has somewhere to go.
  sOrigCopyMatching = SecItemCopyMatching;
  sOrigAdd = SecItemAdd;
  sOrigUpdate = SecItemUpdate;
  sOrigDelete = SecItemDelete;

  NSURL *host = SGShimHostContainer();
  if (host) {
    NSURL *store = [host URLByAppendingPathComponent:@"Library/SpotifyGlassKeychain" isDirectory:YES];
    if ([NSFileManager.defaultManager createDirectoryAtURL:store withIntermediateDirectories:YES
                                                attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:NULL]) {
      sStore = store;
    }
  }
  os_log(sLog, "[spotifyglass] keychain: %{public}@ has keychain groups %{public}@, foreign groups %{public}@",
         NSBundle.mainBundle.bundleIdentifier, [sKeychainGroups componentsJoinedByString:@", "],
         sStore ? [NSString stringWithFormat:@"kept in %@", sStore.path] : @"moved onto the signature's own");
  _dyld_register_func_for_add_image(RebindImage);
}
