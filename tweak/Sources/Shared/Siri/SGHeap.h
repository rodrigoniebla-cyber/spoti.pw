// Finding one of Spotify's live objects by what it can do, for the few services the mod calls into but
// never sees created: the class is looked up among Spotify's own by a selector it implements, and an
// instance of it found by walking the heap, the way FLEX's heap browser does.
//
// Threading: main thread. A walk takes some tens of milliseconds, so callers keep what it finds.
#import <Foundation/Foundation.h>

// Spotify's classes (its executable's, not the system's) whose instances respond to every selector in
// `selectors`, most specific first: a class defining them itself before a subclass inheriting them.
NSArray<Class> *SGSpotifyClassesResponding(NSArray<NSString *> *selectors);
// A live instance of one of `classes` (or a subclass), nil when the heap holds none.
id SGHeapFindInstance(NSArray<Class> *classes);
