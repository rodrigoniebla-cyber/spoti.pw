// See SGHeap.h. The heap walk follows FLEX's FLEXHeapEnumerator: every malloc zone's introspection
// enumerator reports the blocks in use, and a block whose first word, masked the way the runtime masks
// an isa, is one of the wanted classes is an instance of it. Nothing is allocated while the zones are
// locked: matches go into a fixed buffer and are only looked at after the zones are unlocked.
#import <dlfcn.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "SGHeap.h"

static const char *spotifyImage(void) {
    // The executable is image 0.
    return _dyld_get_image_name(0);
}

NSArray<Class> *SGSpotifyClassesResponding(NSArray<NSString *> *selectors) {
    unsigned count = 0;
    const char **names = objc_copyClassNamesForImage(spotifyImage(), &count);
    NSMutableArray<Class> *defining = [NSMutableArray array], *inheriting = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls) continue;
        BOOL all = YES, own = YES;
        for (NSString *name in selectors) {
            SEL sel = NSSelectorFromString(name);
            Method method = class_getInstanceMethod(cls, sel);
            if (!method) { all = NO; break; }
            Class super = class_getSuperclass(cls);
            if (super && class_getInstanceMethod(super, sel) == method) own = NO;
        }
        if (all) [own ? defining : inheriting addObject:cls];
    }
    free(names);
    [defining addObjectsFromArray:inheriting];
    return defining;
}

#pragma mark - the heap walk

// Without messaging the class: a few of the classes listed are roots that answer no message at all.
static BOOL inherits(Class cls, Class wanted) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (c == wanted) return YES;
    }
    return NO;
}

enum { kMostMatches = 64 };

typedef struct {
    const void **wanted;      // class pointers
    size_t *sizes;            // their instance sizes
    unsigned wantedCount;
    uintptr_t mask;
    const void *found[kMostMatches];
    unsigned foundCount;
} SGHeapWalk;

static kern_return_t readMemory(task_t task, vm_address_t address, vm_size_t size, void **data) {
    *data = (void *)address;
    return KERN_SUCCESS;
}

static void rangesInUse(task_t task, void *context, unsigned type, vm_range_t *ranges, unsigned count) {
    SGHeapWalk *walk = context;
    for (unsigned i = 0; i < count && walk->foundCount < kMostMatches; i++) {
        if (ranges[i].size < sizeof(void *)) continue;
        uintptr_t isa = *(const uintptr_t *)ranges[i].address & walk->mask;
        for (unsigned k = 0; k < walk->wantedCount; k++) {
            if ((const void *)isa != walk->wanted[k] || ranges[i].size < walk->sizes[k]) continue;
            walk->found[walk->foundCount++] = (const void *)ranges[i].address;
            break;
        }
    }
}

static uintptr_t isaMask(void) {
    // Exported by libobjc for debuggers; what an isa is masked with to reach the class.
    uintptr_t *mask = dlsym(RTLD_DEFAULT, "objc_debug_isa_class_mask");
    return mask && *mask ? *mask : (uintptr_t)0x0000000ffffffff8ULL;
}

id SGHeapFindInstance(NSArray<Class> *classes) {
    if (!classes.count) return nil;
    // The classes and every subclass of theirs in Spotify's image, since a service is often a subclass.
    NSMutableArray<Class> *all = [classes mutableCopy];
    unsigned count = 0;
    const char **names = objc_copyClassNamesForImage(spotifyImage(), &count);
    for (unsigned i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        for (Class wanted in classes) {
            if (cls && cls != wanted && inherits(cls, wanted)) { [all addObject:cls]; break; }
        }
    }
    free(names);

    SGHeapWalk walk = {0};
    walk.wantedCount = (unsigned)all.count;
    walk.wanted = calloc(walk.wantedCount, sizeof(void *));
    walk.sizes = calloc(walk.wantedCount, sizeof(size_t));
    for (unsigned i = 0; i < walk.wantedCount; i++) {
        walk.wanted[i] = (__bridge const void *)all[i];
        walk.sizes[i] = class_getInstanceSize(all[i]);
    }
    walk.mask = isaMask();

    vm_address_t *zones = NULL;
    unsigned zoneCount = 0;
    if (malloc_get_all_zones(TASK_NULL, readMemory, &zones, &zoneCount) == KERN_SUCCESS) {
        for (unsigned i = 0; i < zoneCount; i++) {
            malloc_zone_t *zone = (malloc_zone_t *)zones[i];
            if (!zone || !zone->introspect || !zone->introspect->enumerator) continue;
            if (zone->introspect->force_lock) zone->introspect->force_lock(zone);
            zone->introspect->enumerator(TASK_NULL, &walk, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)zone, readMemory, rangesInUse);
            if (zone->introspect->force_unlock) zone->introspect->force_unlock(zone);
        }
    }
    free(walk.wanted);
    free(walk.sizes);

    // The first that is still a live object of the class it looked like.
    for (unsigned i = 0; i < walk.foundCount; i++) {
        id object = (__bridge id)walk.found[i];
        Class cls = object_getClass(object);
        for (Class wanted in classes) {
            if (inherits(cls, wanted)) return object;
        }
    }
    return nil;
}
