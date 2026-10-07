// The colours of the playing cover, for the visualizer's Cover gradient colour (Visualizer.h): five colours
// read off the blurred picture by SGPalette.m, its centre and its four quarters, and the gradient stops they
// make round the ring (the ring in the player draws them as a conic gradient, the lock screen's frame samples
// the same).
#import <UIKit/UIKit.h>

// The colours of `image`, SGCoverPaletteColors of them; nil when it has no bitmap to read. Any thread.
extern const NSInteger SGCoverPaletteColors;
NSArray<UIColor *> *SGCoverPaletteOfImage(UIImage *image);

// The playing track's cover colours, read from the artwork Spotify hands the system's now playing, off the
// main thread and once per track (Spotify's artwork handler can wait on the main thread, so it is never
// called there). nil until the first is read, and the last track's until the next is. Main thread.
NSArray<UIColor *> *SGCoverPaletteForPlayingTrack(void);
// The cover as it is on screen, handed over by whoever shows it (the redesigned player's ring), which is read
// in place of the now playing artwork: the same picture as the one seen, at its full size, as soon as it
// shows. The same image again does nothing. Main thread.
void SGCoverPaletteOfferImage(UIImage *image);
// Posted on the main queue when a track's colours have been read.
extern NSNotificationName const SGCoverPaletteDidChangeNotification;

// The stops of a gradient round a ring through `palette`: first to last and back to the first, or, mirrored,
// first to last and back down the other side, so the ring's two halves match. Both ends are the same colour.
NSArray<UIColor *> *SGCoverGradientStops(NSArray<UIColor *> *palette, BOOL mirror);
// The colour of those stops `t` (0...1) of the way round.
UIColor *SGCoverGradientColor(NSArray<UIColor *> *stops, CGFloat t);

// The colours a gradient colour is made of: Spectrum's six hues, or the cover's (the accent until they are
// read; the playing track's, so main thread); nil for a colour that is one colour.
NSArray<UIColor *> *SGVisualizerGradientColours(NSInteger colour, UIColor *accent);
NSArray<UIColor *> *SGVisualizerSpectrumColours(void);
// The stops for a gradient (Visualizer.h's SGVisualizerGradient) through `colours`: along a bar, darkest at
// the inside and lightest at the tip (Spectrum's hues in their order); round the ring once (mirrored or not),
// or there and back `repeats` times. Alternating takes the colours as they are.
NSArray<UIColor *> *SGVisualizerGradientStops(NSArray<UIColor *> *colours, NSInteger gradient, BOOL mirror, BOOL spectrum);
// How many times Repeating goes there and back round the ring.
extern const NSInteger SGVisualizerRepeats;
